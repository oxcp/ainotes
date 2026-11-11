import asyncio
import operator
import re
from collections import OrderedDict
from collections.abc import Coroutine
from typing import Annotated, Any, TypedDict
from uuid import UUID, uuid4

from langgraph.graph import END, START, StateGraph
from pydantic import ValidationError

from shared.charts import (
    CHART_PROMPT,
    DOCUMENT_CHART_PROMPT,
    chart_sources,
    document_source,
    resolve_charts,
)
from shared.config import Settings
from shared.contracts import (
    Answer,
    ChartSelection,
    DocumentChartExtraction,
    FileRef,
    Mode,
    Question,
    RagResult,
    Review,
    SQLResult,
    StudioError,
)
from shared.database import Repository
from shared.models import Foundry
from shared.observability import clock, event, failure
from shared.planning import inventory_summary, plan_question
from shared.storage import BlobStore


class State(TypedDict, total=False):
    request_id: str
    workspace_id: str
    conversation_id: str
    request_type: str
    question: dict
    file: dict
    mode: str
    plan: dict
    rag_result: dict
    sql_result: dict
    processing_result: dict
    answer: dict
    review: dict
    charts: list[dict]
    errors: Annotated[list[dict], operator.add]
    revision_count: int


class Orchestrator:
    def __init__(
        self, config: Settings, repo: Repository, blob: BlobStore, model: Foundry, *, data, rag, sql
    ):
        self.config, self.repo, self.blob, self.model = config, repo, blob, model
        self.data, self.rag, self.sql = data, rag, sql
        self.runs: OrderedDict[str, dict] = OrderedDict()
        self.tasks: set[asyncio.Task] = set()

    async def get_workspace(self, workspace: UUID):
        return await asyncio.to_thread(self.repo.workspace, workspace)

    async def create_workspace(self, name: str):
        return await asyncio.to_thread(self.repo.create_workspace, name)

    async def list_workspaces(self):
        return await asyncio.to_thread(self.repo.workspaces)

    async def list_data(self, workspace: UUID, kind: str):
        await self.get_workspace(workspace)
        method = self.repo.catalog if kind == "datasets" else self.repo.documents
        return await asyncio.to_thread(method, workspace)

    async def file_status(self, workspace: UUID, file_id: UUID):
        await self.get_workspace(workspace)
        result = await asyncio.to_thread(self.repo.document, workspace, file_id)
        return {k: result[k] for k in ("id", "filename", "processing_status", "metadata")}

    async def upload(
        self, workspace: UUID, name: str, mime: str, data: bytes, conversation: UUID
    ):
        await self.get_workspace(workspace)
        ref = await asyncio.to_thread(self.blob.upload, workspace, name, mime, data)
        record = await asyncio.to_thread(self.repo.register_file, ref)
        registered = FileRef.model_validate(record["metadata"]["file"])
        return await self.start(workspace, conversation, ref=registered)

    async def register_upload(self, workspace: UUID, ref: FileRef, conversation: UUID):
        await self.get_workspace(workspace)
        if ref.workspace_id != workspace or ref.blob_uri != self.blob.uri(ref):
            raise StudioError("FORBIDDEN_FILE", "File reference does not match the workspace storage.", 403)
        record = await asyncio.to_thread(self.repo.register_file, ref)
        registered = FileRef.model_validate(record["metadata"]["file"])
        return await self.start(workspace, conversation, ref=registered)

    def build_graph(self, emit):
        graph = StateGraph(State)

        def note(state, stage, message):
            emit(stage, message)
            event(
                stage,
                "running",
                message,
                request_id=state["request_id"],
                workspace_id=state["workspace_id"],
                conversation_id=state["conversation_id"],
            )

        async def receive(state):
            note(state, "receive_request", "Validating workspace and request...")
            await self.get_workspace(UUID(state["workspace_id"]))
            return {}

        async def plan(state):
            note(state, "classify_and_plan", "Understanding your request and selecting data sources...")
            workspace = UUID(state["workspace_id"])
            documents, datasets = await asyncio.gather(
                asyncio.to_thread(self.repo.documents, workspace),
                asyncio.to_thread(self.repo.catalog, workspace),
            )
            result = await plan_question(
                self.model, Question.model_validate(state["question"]), inventory_summary(documents, datasets)
            )
            if (
                result.chart_intent == "requested"
                and result.rag_strategy == "review_overview"
                and result.mode == Mode.RAG
            ):
                result.mode = Mode.HYBRID
                result.sql_goal = result.sql_goal or state["question"]["message"]
                result.reason = (
                    "Requested review visualization requires SQL-backed numeric rows and review evidence."
                )
            tasks = []
            if result.mode in {Mode.RAG, Mode.HYBRID}:
                tasks.append({"worker": "rag_agent", "goal": result.rag_goal, "depends_on": []})
            if result.mode in {Mode.SQL, Mode.HYBRID}:
                tasks.append({"worker": "sql_agent", "goal": result.sql_goal, "depends_on": []})
            return {"mode": result.mode.value, "plan": {**result.model_dump(mode="json"), "tasks": tasks}}

        async def direct(state):
            note(state, "direct_llm", "Preparing a direct model response without data queries...")
            payload = state["question"]
            if state["plan"].get("chart_intent") == "requested":
                # Direct charts use current-request values, not stale assistant claims about rendering.
                payload = {**payload, "recent_context": []}
            answer = await self.model.structured(
                "Answer the question directly. No workspace data was retrieved. "
                "Do not invent chart data. If visualization needs data, ask for it. "
                "Explicit before/after percentages in the current request ARE available chart data; "
                "do not ask for SQL or uploads when the user has supplied the values. "
                "Describe them as user-provided, not independently verified document facts. "
                "The UI renders actual inline SVG charts in a separate chart-selection step after this "
                "draft. Do not claim you cannot draw charts or only provide data/code/instructions. "
                "Your text and the rendered chart form ONE user-visible response, not separate outputs. "
                "Do not include any text-only-output or no-rendered-graphics disclaimer, in any language. "
                "For a chart request, describe the comparison briefly instead of recommending that "
                "the user draw the requested chart themselves. "
                "Supported visualizations are bar, line, pie and numeric comparison table.",
                payload,
                Answer,
            )
            return {"answer": answer.model_dump()}

        async def process(state):
            note(state, "process_uploaded_file", "Processing the uploaded file...")
            result = await self.data.run(
                UUID(state["workspace_id"]), FileRef.model_validate(state["file"]), emit
            )
            return {"processing_result": result.model_dump()}

        async def worker(state, name):
            note(
                state,
                name,
                "Searching uploaded documents..." if name == "rag_search" else "Querying structured data...",
            )
            workspace = UUID(state["workspace_id"])
            for retry in range(2):
                try:
                    call: Coroutine[Any, Any, RagResult | SQLResult]
                    if name == "rag_search":
                        call = self.rag.run(
                            workspace,
                            state["plan"]["rag_goal"] or state["question"]["message"],
                            state["question"].get("filters", {}),
                            state["plan"].get("rag_strategy", "semantic"),
                        )
                    else:
                        call = self.sql.run(
                            workspace, state["plan"]["sql_goal"] or state["question"]["message"]
                        )
                    result = await asyncio.wait_for(call, timeout=self.config.worker_timeout)
                    return {("rag_result" if name == "rag_search" else "sql_result"): result.model_dump()}
                except TimeoutError as exc:
                    failure(exc, request_id=state["request_id"], agent=name)
                    if retry == 0:
                        emit(name, "Read operation timed out; retrying once...")
                        continue
                    return {"errors": [{"worker": name, "code": "WORKER_TIMEOUT", "retry_count": retry}]}
                except Exception as exc:
                    failure(exc, request_id=state["request_id"], agent=name)
                    return {
                        "errors": [
                            {
                                "worker": name,
                                "code": exc.code if isinstance(exc, StudioError) else "WORKER_FAILED",
                                "retry_count": retry,
                            }
                        ]
                    }
            raise AssertionError("Unreachable")

        async def rag(state):
            return await worker(state, "rag_search")

        async def sql_node(state):
            return await worker(state, "sql_query")

        async def aggregate(state):
            note(state, "aggregate_results", "Combining evidence and checking worker outcomes...")
            return {}

        def evidence(state):
            payload = {k: state[k] for k in ("rag_result", "sql_result", "errors") if k in state}
            if state.get("question"):
                # History resolves intent during planning; old assistant facts/citations are not evidence.
                payload["question"] = {k: v for k, v in state["question"].items() if k != "recent_context"}
                payload["retrieval_goals"] = {
                    k: state.get("plan", {}).get(k, "") for k in ("rag_goal", "sql_goal")
                }
            return payload

        async def visualize(state):
            intent = state.get("plan", {}).get("chart_intent", "auto")
            if intent == "none":
                return {"charts": []}
            if state.get("revision_count") and state.get("charts"):
                return {}
            try:
                sources = chart_sources(state)
                retrieved = state.get("rag_result", {})
                if (
                    intent == "requested"
                    and "user" not in sources
                    and retrieved.get("results")
                    and retrieved.get("retrieval_method", "semantic") == "semantic"
                    and (
                        "sql" not in sources
                        or any(
                            "sentiment_label" not in item.get("metadata", {}) for item in retrieved["results"]
                        )
                    )
                ):
                    note(
                        state, "prepare_charts", "Extracting chart values with document quotation anchors..."
                    )
                    extracted = await asyncio.wait_for(
                        self.model.structured(
                            DOCUMENT_CHART_PROMPT,
                            {
                                "question": {"message": state["question"]["message"]},
                                "passages": retrieved["results"],
                            },
                            DocumentChartExtraction,
                        ),
                        timeout=self.config.worker_timeout,
                    )
                    source = document_source(extracted, retrieved["results"], state["workspace_id"])
                    if source:
                        sources["document"] = source
                if intent != "requested":
                    sources.pop("rag", None)
                    if len(sources.get("sql", {}).get("rows", [])) < 2:
                        sources.pop("sql", None)
                if not sources:
                    if intent == "requested":
                        raise StudioError(
                            "CHART_DATA_UNAVAILABLE",
                            "No suitable numeric chart data was retrieved. Narrow the metrics/periods or upload the relevant data.",
                            422,
                        )
                    return {"charts": []}
                note(state, "prepare_charts", "Selecting grounded charts from available numeric results...")
                purpose = CHART_PROMPT
                if state.get("rag_result", {}).get("retrieval_method") == "review_overview":
                    purpose += (
                        "\nFor a qualitative review overview, prefer charts=[] unless the question explicitly "
                        "requests numeric visualization. Review ratings and source_row_id are not additive "
                        "sentiment counts; do not make a pie chart or infer distributions from these passages."
                    )
                payload = {
                    "question": state.get("question", {}),
                    "analysis": state.get("answer", {}),
                    "required_changes": state.get("review", {}),
                    "sources": sources,
                }
                for attempt in range(2):
                    try:
                        selection = await asyncio.wait_for(
                            self.model.structured(purpose, payload, ChartSelection),
                            timeout=self.config.worker_timeout,
                        )
                        charts = resolve_charts(selection, sources)
                        break
                    except (ValidationError, StudioError) as exc:
                        if attempt or (isinstance(exc, StudioError) and exc.code != "INVALID_CHART"):
                            raise
                        failure(exc, request_id=state["request_id"], stage="prepare_charts")
                        payload["validation_error"] = str(exc)
                        note(state, "prepare_charts", "Correcting chart selection against source cells...")
                if not charts and intent == "requested":
                    raise StudioError(
                        "CHART_DATA_UNAVAILABLE",
                        selection.reason
                        or "The retrieved values do not support the requested chart and statistical scope.",
                        422,
                    )
                return {"charts": [c.model_dump(mode="json", exclude_defaults=True) for c in charts]}
            except Exception as exc:
                failure(exc, request_id=state["request_id"], stage="prepare_charts")
                code = (
                    "INVALID_CHART"
                    if isinstance(exc, ValidationError)
                    else exc.code
                    if isinstance(exc, StudioError)
                    else "CHART_FAILED"
                )
                return {
                    "charts": [],
                    "errors": [
                        {
                            "worker": "prepare_charts",
                            "code": code,
                            "message": exc.message
                            if isinstance(exc, StudioError)
                            else "Charts could not be prepared from the available data. The text answer is reviewed separately.",
                            "retry_count": 0,
                        }
                    ],
                }

        async def generate(state):
            note(state, "generate_final_response", "Preparing the final answer...")
            if state["mode"] == "DIRECT" and state.get("answer") and not state.get("revision_count"):
                return {}
            payload = evidence(state)
            if state.get("review"):
                payload["required_changes"] = state["review"]
                payload["previous_answer"] = state.get("answer")
                payload["charts"] = state.get("charts", [])
            answer = await self.model.structured(
                "Synthesize and polish a presentation-ready answer. Separate retrieved evidence, calculated facts, "
                "interpretation, recommendations and limitations. Use only supplied citation IDs. "
                "Each rag_result.results[].record_id is a supplied citation ID: put the IDs of supporting "
                "passages in citation_ids when summarizing review evidence. "
                "Inline bracket citations must use those same exact record_id values, never document_id "
                "or a reconstructed UUID. Keep the answer concise; do not repeat every figure in every section. "
                "When there are no retrieved passages, citation_ids MUST be []; SQL text, table names, "
                "column names, chart source names and request IDs are NOT citation IDs. "
                "Do not invent calculations. Explicitly disclose failed workers and insufficient retrieval. "
                "Charts support bar, line, pie and numeric comparison table only; explain unsupported requests. "
                "Only when visualization was requested, explain unavailable numeric chart data. "
                "For a qualitative summary or ordinary text answer, do not add unsolicited chart recommendations "
                "or chart-unavailability disclaimers. "
                "Report figures in retrieved prose CAN be charted after exact-quote numeric extraction. "
                "SQL results can be charted directly. Neither requires values to be repeated in the question. "
                "Do not invent values from general knowledge or confuse retrieval counts with population counts. "
                "Explicit before/after percentages supplied in the current question are valid chart input "
                "even without SQL rows. Distinguish user-provided numbers from independently verified "
                "document facts; do not merely recommend a chart when these values can be plotted. "
                "The UI renders actual inline SVG charts. When revising, supplied charts are the "
                "renderable specifications: do not claim only data/instructions are available or "
                "that charts cannot be drawn when these specifications are present. "
                "Respect retrieval_method, truncated and warnings: an overview subset is not a representative "
                "sample or a whole-dataset summary. Ground qualitative statements in the supplied passages. "
                "For cross-source comparisons, explicitly check each source/theme against actual passage text. "
                "If one report or theme is missing, preserve verified findings and name the evidence gap; "
                "do not claim a completed comparison or shared trend without support from both sources. "
                "Contents pages, acknowledgments and repeated footers do not establish consumer findings. "
                "History and planner goals are not verified data. Skipped ingestion records can be empty, "
                "Retrieval warnings describe execution/coverage only; candidate counts and query words "
                "are never evidence of matching review traits. Match review rating/sentiment in metadata "
                "before using a passage as a mismatch example. SQL counts remain valid independently "
                "of missing qualitative examples: preserve verified statistics and disclose the text gap. "
                "short or duplicate text, not additional customer reviews. When revising, correct the supplied "
                "previous_answer against current evidence rather than assuming review suggestions are facts.",
                payload,
                Answer,
            )
            return {"answer": answer.model_dump()}

        async def review(state):
            note(state, "review_evidence", "Reviewing answer, numerical claims and citations...")
            payload = {**evidence(state), "answer": state["answer"], "charts": state.get("charts", [])}
            result = await self.model.structured(
                "Review the actual draft against question and supplied evidence. Check numerical claims against "
                "the applicable SQL rows, retrieved passages or explicit user input; correct citations and workspace, labeled "
                "recommendations, unsupported percentages/market claims, conflicting evidence and missing data. "
                "Check chart titles, units, ordering, selected rows and pie parts-of-whole semantics against "
                "sources. Report chart-only issues in chart_issues so the server removes misleading charts; "
                "Document charts include citations with exact quotes and record IDs for the plotted values. "
                "Validate EVERY value-to-metric/period mapping, unit/scale, scope and comparability against "
                "the ORIGINAL passages, not merely the presence of the same number in a quote. Reject "
                "reversed periods, mixed populations, percentages vs percentage-point changes, duplicate "
                "metrics, invented labels, missing requested metrics, and unsupported or conflicting values. "
                "Document pies require a quoted exhaustive mutually exclusive partition of one population; "
                "document lines require explicit chronological/sequence labels. Quoted report statistics "
                "are valid WITHOUT SQL confirmation; never require SQL for figures already in reports. "
                "A grouped bar may compare each metric's OWN before/after rate with differing denominators "
                "if the differing scope is disclosed; it must not imply a common denominator or add rates. "
                "Charts labelled User-provided must match the explicit percentages in question.message; "
                "they do not require SQL or document confirmation to visualize supplied values. "
                "Their caption does not claim independent verification. Reject any unsupported claim "
                "that user-provided inputs are verified report facts or a full-dataset aggregation. "
                "When charts is non-empty, the UI renders them as real inline SVG graphics. Require a "
                "text revision if the draft falsely says no chart is generated, only data/instructions "
                "are provided, or the assistant cannot draw charts. This is an answer-text issue, "
                "not a reason to remove valid charts. "
                "Judge the combined response, not just the text field: '不包含实际渲染图形' and "
                "'只提供数据' are false when charts is non-empty, even if qualified as 'current output'. "
                "do not block or revise otherwise valid answer text solely for chart issues. "
                "DIRECT creative/general answers need no workspace evidence. "
                "An honestly scoped partial answer may be approved: missing requested evidence alone is not "
                "an unsupported claim when the draft clearly discloses the gap and preserves only verified "
                "findings. Still reject claims of shared trends or comparisons without both sources. "
                "A review_overview uses stored passages, not semantic scores; null similarity is expected. "
                "The record_id fields in rag_result.results ARE citation IDs; require the draft's "
                "citation_ids to identify supporting passages for a review overview. "
                "Require disclosure of truncated coverage, and reject population claims from a bounded subset. "
                "History and planner goals do not establish facts. Ingestion skipped_records does not establish "
                "a count of missing reviews. When charts is empty, chart_issues must be empty; "
                "do not report an already disclosed chart-generation error as a new chart issue. "
                "Return approved, revise or blocked.",
                payload,
                Review,
            )
            if not state.get("charts"):
                result.chart_issues = []
            allowed = {item["record_id"] for item in state.get("rag_result", {}).get("results", [])}
            if set(state["answer"].get("citation_ids", [])) - allowed:
                if result.status != "blocked":
                    result.status = "blocked" if state.get("revision_count") else "revise"
                result.required_changes.append(
                    "Unrecognized citation IDs. Use only actual RAG record_id values; "
                    "when no RAG passages were returned, citation_ids MUST be []. SQL is not a citation ID."
                )
            if allowed:
                inline = {
                    citation.lower()
                    for text in state["answer"].values()
                    if isinstance(text, str)
                    for bracket in re.findall(r"[\[【]([^\]】\n]+)[\]】]", text)
                    for citation in re.findall(
                        r"\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b", bracket
                    )
                }
                if inline - {item.lower() for item in allowed}:
                    if result.status == "approved":
                        result.status = "revise"
                    result.required_changes.append(
                        "Replace unrecognized inline citation UUIDs with the exact supporting record_id, "
                        "not document_id. Remove any claim without a supporting passage."
                    )
            if (
                state.get("rag_result", {}).get("retrieval_method") == "review_overview"
                and allowed
                and not state["answer"].get("citation_ids")
            ):
                if result.status == "approved":
                    result.status = "revise"
                result.required_changes.append(
                    "Cite the supporting rag_result.results[].record_id values in citation_ids."
                )
            if any(
                item["workspace_id"] != state["workspace_id"]
                for item in state.get("rag_result", {}).get("results", [])
            ):
                result.status = "blocked"
            update: dict[str, Any] = {"review": result.model_dump()}
            if result.chart_issues:
                update.update(
                    charts=[],
                    errors=[
                        {
                            "worker": "prepare_charts",
                            "code": "INVALID_CHART",
                            "message": "Charts did not pass evidence review and were omitted. See review details.",
                            "retry_count": 0,
                        }
                    ],
                )
            return update

        async def revise(state):
            emit("revision", "Revising the answer once based on evidence review...")
            return {"revision_count": 1}

        async def emit_response(state):
            emit("emit_response", "Response ready.")
            return {}

        async def handle_error(state):
            emit("handle_error", "The request could not produce a verified answer.")
            return {
                "charts": [],
                "answer": Answer(
                    interpretation="Unable to produce a verified answer.",
                    limitations="Required data operations failed or evidence review blocked the response.",
                ).model_dump(),
            }

        for name, node in [
            ("receive_request", receive),
            ("classify_and_plan", plan),
            ("direct_llm", direct),
            ("process_uploaded_file", process),
            ("rag_search", rag),
            ("sql_query", sql_node),
            ("aggregate_results", aggregate),
            ("generate_final_response", generate),
            ("prepare_charts", visualize),
            ("review_evidence", review),
            ("revise", revise),
            ("emit_response", emit_response),
            ("handle_error", handle_error),
        ]:
            graph.add_node(name, node)
        graph.add_edge(START, "receive_request")
        graph.add_conditional_edges(
            "receive_request",
            lambda s: "process_uploaded_file" if s["request_type"] == "FILE_UPLOAD" else "classify_and_plan",
        )
        graph.add_conditional_edges(
            "classify_and_plan",
            lambda s: {
                "DIRECT": ["direct_llm"],
                "RAG": ["rag_search"],
                "SQL": ["sql_query"],
                "HYBRID": ["rag_search", "sql_query"],
            }[s["mode"]],
        )
        graph.add_edge("process_uploaded_file", "prepare_charts")
        graph.add_edge("direct_llm", "generate_final_response")
        graph.add_edge("rag_search", "aggregate_results")
        graph.add_edge("sql_query", "aggregate_results")
        graph.add_conditional_edges(
            "aggregate_results",
            lambda s: (
                "generate_final_response" if s.get("rag_result") or s.get("sql_result") else "handle_error"
            ),
        )
        graph.add_edge("generate_final_response", "prepare_charts")
        graph.add_conditional_edges(
            "prepare_charts",
            lambda s: "emit_response" if s["request_type"] == "FILE_UPLOAD" else "review_evidence",
        )
        graph.add_conditional_edges(
            "review_evidence",
            lambda s: (
                "emit_response"
                if s["review"]["status"] == "approved"
                else "revise"
                if s["review"]["status"] == "revise" and s.get("revision_count", 0) == 0
                else "handle_error"
            ),
        )
        graph.add_edge("revise", "generate_final_response")
        graph.add_edge("handle_error", "emit_response")
        graph.add_edge("emit_response", END)
        return graph.compile()

    def workflow_timeout(self, upload: bool) -> float:
        return self.config.request_timeout + (self.config.ingestion_timeout + 120 if upload else 0)

    async def start(
        self,
        workspace: UUID,
        conversation: UUID,
        question: Question | None = None,
        ref: FileRef | None = None,
    ):
        await self.get_workspace(workspace)
        if len(self.tasks) >= 4:
            raise StudioError("BUSY", "Four workflows are already active; retry later.", 429, True)
        while len(self.runs) >= self.config.max_runs:
            removable = next((k for k, v in self.runs.items() if v["status"] != "running"), None)
            if removable is None:
                raise StudioError("BUSY", "Run capacity reached.", 429, True)
            del self.runs[removable]
        request_id = str(uuid4())
        state: State = {
            "request_id": request_id,
            "workspace_id": str(workspace),
            "conversation_id": str(conversation),
            "request_type": "FILE_UPLOAD" if ref else "QUESTION",
            "errors": [],
            "revision_count": 0,
        }
        if question:
            if any(len(text) > 4000 for text in question.recent_context):
                raise StudioError("CONTEXT_LIMIT", "Recent conversation context is too large.")
            state["question"] = question.model_dump(mode="json")
        if ref:
            state["file"] = ref.model_dump(mode="json")
        self.runs[request_id] = {
            "request_id": request_id,
            "workspace_id": str(workspace),
            "status": "running",
            "progress_events": [],
        }
        task = asyncio.create_task(self.execute(state))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return {
            "request_id": request_id,
            "run_id": request_id,
            "status": "running",
            "file_id": str(ref.file_id) if ref else None,
            "poll_timeout_seconds": self.workflow_timeout(ref is not None) + 60,
        }

    async def execute(self, state: State):
        run = self.runs[state["request_id"]]
        start = clock()

        def emit(stage, message):
            run["progress_events"].append(event(stage, "running", message, request_id=state["request_id"]))
            run["progress_events"] = run["progress_events"][-100:]

        try:
            result = await asyncio.wait_for(
                self.build_graph(emit).ainvoke(state, {"recursion_limit": 24}),
                timeout=self.workflow_timeout(state["request_type"] == "FILE_UPLOAD"),
            )
            run.update(
                {
                    k: result[k]
                    for k in (
                        "mode",
                        "plan",
                        "answer",
                        "review",
                        "rag_result",
                        "sql_result",
                        "processing_result",
                        "errors",
                        "revision_count",
                        "charts",
                    )
                    if k in result
                }
            )
            blocked = result.get("review", {}).get("status") not in {None, "approved"}
            no_result = bool(result.get("errors")) and not (
                result.get("rag_result")
                or result.get("sql_result")
                or result.get("processing_result")
                or (result.get("mode") == "DIRECT" and result.get("answer"))
            )
            run["status"] = (
                "failed" if blocked or no_result else "partial" if result.get("errors") else "completed"
            )
        except Exception as exc:
            failure(exc, request_id=state["request_id"])
            run.update(
                status="failed",
                error={
                    "code": exc.code if isinstance(exc, StudioError) else "WORKFLOW_FAILED",
                    "message": exc.message
                    if isinstance(exc, StudioError)
                    else "Workflow failed; check server diagnostics.",
                    "request_id": state["request_id"],
                    "retryable": exc.retryable
                    if isinstance(exc, StudioError)
                    else isinstance(exc, TimeoutError),
                    "details": {},
                },
            )
        run["latency_ms"] = round((clock() - start) * 1000)
        completed_run = dict(run)
        run["status"] = "running"
        try:
            await asyncio.to_thread(self.repo.save_run, UUID(state["workspace_id"]), completed_run)
            run["status"] = completed_run["status"]
        except Exception as exc:
            failure(exc, request_id=state["request_id"], stage="persist_run")
            run["status"] = "failed"
            run["error"] = {
                "code": "RUN_PERSIST_FAILED",
                "message": "Run could not be persisted.",
                "request_id": state["request_id"],
                "retryable": True,
                "details": {},
            }

    async def get_run(self, workspace: UUID, run_id: UUID):
        await self.get_workspace(workspace)
        run = self.runs.get(str(run_id))
        if run and run["workspace_id"] == str(workspace):
            return run
        return await asyncio.to_thread(self.repo.run, workspace, run_id)

    async def close(self):
        if self.tasks:
            await asyncio.gather(*self.tasks)
        await self.model.close()
        await asyncio.to_thread(self.repo.close)
        await asyncio.to_thread(self.blob.close)
