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

_CITATION_BRACKET = re.compile(r"[\[【]([^\]】\n]+)[\]】]")
_CITATION_REFERENCE = re.compile(
    r"\b(?:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|R\d+)\b", re.IGNORECASE
)
ANSWER_LANGUAGE_PROMPT = """Use answer_language for all generated explanatory prose, including answer
sections, recommendations, limitations, review feedback and chart titles/reasons. If it is empty,
infer the language from the CURRENT user message (question.message, or top-level message for DIRECT).
An explicit response-language request in that message takes precedence. For mixed-language messages,
follow the surrounding request, not quoted text, filenames or technical terms. Do not copy the language
of a previous answer, English worker goals, SQL output or retrieved sources. Revisions keep the same rule.
Preserve original quotations, proper names, code, SQL, exact source column/series identifiers, citation
IDs and JSON schema keys; translate the surrounding explanation, not evidence or machine identifiers.
When reviewing, a wrong-language narrative needs status=revise with a specific language correction,
not immediate blocking or removal of otherwise valid evidence/charts. Do not rerun workers just to translate."""


def _map_answer_citations(answer: dict[str, Any], references: dict[str, str]) -> dict[str, Any]:
    def replace_bracket(match: re.Match[str]) -> str:
        return _CITATION_REFERENCE.sub(
            lambda ref: references.get(ref.group(), ref.group()), match.group()
        )

    mapped = dict(answer)
    for key, value in answer.items():
        if key == "citation_ids":
            mapped[key] = [references.get(ref, ref) for ref in value]
        elif isinstance(value, str):
            mapped[key] = _CITATION_BRACKET.sub(replace_bracket, value)
    return mapped


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
    chart_feedback: list[str]
    document_chart_extraction: dict
    text_only_fallback: bool
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
            payload = {
                **state["question"],
                "answer_language": state["plan"].get("answer_language", ""),
            }
            if state["plan"].get("chart_intent") == "requested":
                # Direct charts use current-request values, not stale assistant claims about rendering.
                payload["recent_context"] = []
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
                "Supported visualizations are bar, line, pie and numeric comparison table.\n"
                + ANSWER_LANGUAGE_PROMPT,
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
            question = state["question"]["message"]
            goal = state["plan"]["rag_goal" if name == "rag_search" else "sql_goal"]
            if goal and goal != question:
                combined = (
                    f"Current user request:\n{question}\n\n"
                    f"Planner's worker goal (may omit requested scope):\n{goal}"
                )
                if len(combined) <= 4000:
                    question = combined
                else:
                    event(
                        name, "bounded",
                        "Worker goal omitted to preserve the full current request within the input limit.",
                        request_id=state["request_id"],
                    )
            for retry in range(2):
                try:
                    call: Coroutine[Any, Any, RagResult | SQLResult]
                    if name == "rag_search":
                        call = self.rag.run(
                            workspace,
                            question,
                            state["question"].get("filters", {}),
                            state["plan"].get("rag_strategy", "semantic"),
                        )
                    else:
                        call = self.sql.run(
                            workspace, question
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
                                "message": exc.message
                                if isinstance(exc, StudioError)
                                else "Worker operation failed. Check the worker logs.",
                                "retry_count": retry,
                            }
                        ]
                    }
            raise AssertionError("Unreachable")

        async def rag(state):
            return await worker(state, "rag_search")

        async def sql_node(state):
            return await worker(state, "sql_query")

        def aggregate_route(state):
            errors = state.get("errors", [])
            if (
                state["mode"] == "SQL"
                and not state.get("sql_result")
                and not state.get("rag_result")
                and any(item["worker"] == "sql_query" for item in errors)
                and not any(item["worker"] == "rag_search" for item in errors)
            ):
                return "rag_search"
            return "prepare_charts" if state.get("rag_result") or state.get("sql_result") else "handle_error"

        async def aggregate(state):
            note(state, "aggregate_results", "Combining evidence and checking worker outcomes...")
            if aggregate_route(state) == "rag_search":
                note(
                    state, "rag_fallback",
                    "SQL data is unavailable; searching documents for independently supported findings...",
                )
                goal = state["question"]["message"]
                return {"plan": {
                    **state["plan"],
                    "rag_goal": goal,
                    "rag_strategy": "semantic",
                    "tasks": [
                        *state["plan"]["tasks"],
                        {"worker": "rag_agent", "goal": goal, "depends_on": ["sql_agent"]},
                    ],
                }}
            return {}

        def evidence(state):
            payload = {k: state[k] for k in ("rag_result", "sql_result", "errors") if k in state}
            payload["answer_language"] = state.get("plan", {}).get("answer_language", "")
            payload["sql_unavailable"] = not state.get("sql_result") and any(
                item["worker"] == "sql_query" for item in state.get("errors", [])
            )
            payload["chart_data_unavailable"] = not state.get("charts") and any(
                item["code"] == "CHART_DATA_UNAVAILABLE" for item in state.get("errors", [])
            )
            payload["chart_unavailable"] = not state.get("charts") and any(
                item["worker"] == "prepare_charts" for item in state.get("errors", [])
            )
            payload["text_only_fallback"] = state.get("text_only_fallback", False)
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
            if state.get("revision_count") and not state.get("chart_feedback"):
                return {}
            document_extraction = {}
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
                    extraction_payload = {
                        "question": {"message": state["question"]["message"]},
                        "passages": retrieved["results"],
                        "required_changes": [
                            *state.get("chart_feedback", []),
                            *state.get("review", {}).get("required_changes", []),
                        ],
                    }
                    if state.get("document_chart_extraction"):
                        extraction_payload["previous_extraction"] = state["document_chart_extraction"]
                    for attempt in range(2):
                        extracted = None
                        try:
                            extracted = await asyncio.wait_for(
                                self.model.structured(
                                    DOCUMENT_CHART_PROMPT,
                                    extraction_payload,
                                    DocumentChartExtraction,
                                ),
                                timeout=self.config.worker_timeout,
                            )
                            source = document_source(extracted, retrieved["results"], state["workspace_id"])
                            document_extraction = extracted.model_dump()
                            break
                        except (ValidationError, StudioError) as exc:
                            if attempt or (isinstance(exc, StudioError) and exc.code != "INVALID_CHART"):
                                raise
                            failure(exc, request_id=state["request_id"], stage="document_chart_extraction")
                            extraction_payload["validation_error"] = str(exc)
                            if extracted is not None:
                                extraction_payload["previous_extraction"] = extracted.model_dump()
                            note(
                                state, "prepare_charts",
                                "Correcting document chart extraction against original passages...",
                            )
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
                            "No explicit numeric data suitable for the requested chart was found in the "
                            "available evidence. Only supported text findings can be provided; "
                            "chart values must not be inferred.",
                            422,
                        )
                    return {"charts": []}
                note(state, "prepare_charts", "Selecting grounded charts from available numeric results...")
                purpose = CHART_PROMPT + "\n" + ANSWER_LANGUAGE_PROMPT
                if state.get("rag_result", {}).get("retrieval_method") == "review_overview":
                    purpose += (
                        "\nFor a qualitative review overview, prefer charts=[] unless the question explicitly "
                        "requests numeric visualization. Review ratings and source_row_id are not additive "
                        "sentiment counts; do not make a pie chart or infer distributions from these passages."
                    )
                payload = {
                    "answer_language": state.get("plan", {}).get("answer_language", ""),
                    "question": {
                        k: v for k, v in state.get("question", {}).items() if k != "recent_context"
                    },
                    "analysis": state.get("answer", {}),
                    "required_changes": state.get("review", {}),
                    "chart_feedback": state.get("chart_feedback", []),
                    "sources": sources,
                }
                for attempt in range(2):
                    selection = None
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
                        if selection is not None:
                            payload["previous_selection"] = selection.model_dump()
                        note(state, "prepare_charts", "Correcting chart selection against source cells...")
                assert selection is not None
                if not charts and intent == "requested":
                    raise StudioError(
                        "CHART_DATA_UNAVAILABLE",
                        selection.reason
                        or "The retrieved values do not support the requested chart and statistical scope.",
                        422,
                    )
                return {
                    "charts": [c.model_dump(mode="json", exclude_defaults=True) for c in charts],
                    "document_chart_extraction": document_extraction,
                }
            except Exception as exc:
                failure(exc, request_id=state["request_id"], stage="prepare_charts")
                code = (
                    "INVALID_CHART"
                    if isinstance(exc, ValidationError)
                    else exc.code
                    if isinstance(exc, StudioError)
                    else "CHART_FAILED"
                )
                if isinstance(exc, StudioError):
                    message = exc.message
                elif isinstance(exc, ValidationError):
                    message = "Chart output schema was invalid: " + "; ".join(
                        ".".join(str(part) for part in item["loc"]) + ": " + item["type"]
                        for item in exc.errors(include_input=False)
                    )[:1000]
                else:
                    message = (
                        "Charts could not be prepared from the available data. "
                        "The text answer is reviewed separately."
                    )
                return {
                    "charts": [],
                    "document_chart_extraction": document_extraction,
                    "errors": [
                        {
                            "worker": "prepare_charts",
                            "code": code,
                            "message": message,
                            "review_issues": state.get("chart_feedback", []),
                            "retry_count": 0,
                        }
                    ],
                }

        async def generate(state):
            note(state, "generate_final_response", "Preparing the final answer...")
            if state["mode"] == "DIRECT" and state.get("answer") and not state.get("revision_count"):
                return {}
            payload = evidence(state)
            payload["charts"] = state.get("charts", [])
            passages = state.get("rag_result", {}).get("results", [])
            references = {f"R{index}": item["record_id"] for index, item in enumerate(passages, 1)}
            # Only synthesis sees short references; review, charts and persisted evidence retain real IDs.
            if "rag_result" in payload:
                payload["rag_result"] = {
                    **payload["rag_result"],
                    "results": [
                        {
                            **{k: v for k, v in item.items() if k not in {"workspace_id", "document_id"}},
                            "record_id": reference,
                        }
                        for reference, item in zip(references, passages)
                    ],
                }
            if state.get("review"):
                payload["required_changes"] = state["review"]
                payload["previous_answer"] = _map_answer_citations(
                    state["answer"], {record: reference for reference, record in references.items()}
                )
                payload["charts"] = state.get("charts", [])
            answer = await self.model.structured(
                "Synthesize and polish a presentation-ready answer. "
                "Separate retrieved evidence, calculated facts, "
                "interpretation, recommendations and limitations. Use only supplied citation IDs. "
                "Each rag_result.results[].record_id is a supplied citation ID: put the IDs of supporting "
                "passages in citation_ids when summarizing review evidence. "
                "For this draft, these are short references such as R1 and R2, not UUIDs. Use [R1] or "
                "[R1, R2] inline and the same references in citation_ids. The server resolves them to "
                "original record IDs before review. Use only references present in the supplied results; "
                "never invent a reference, copy document_id, or reconstruct a UUID. "
                "Keep the answer concise; do not repeat every figure in every section. "
                "When there are no retrieved passages, citation_ids MUST be []; SQL text, table names, "
                "column names, chart source names and request IDs are NOT citation IDs. "
                "Do not invent calculations. Explicitly disclose failed workers and insufficient retrieval. "
                "When sql_unavailable is true, continue with independently supported RAG findings, "
                "even if the original route was SQL. In limitations explicitly state that the SQL "
                "portion's requested data is missing and its calculations could not be completed. "
                "Do not replace missing SQL totals/rates with zero, estimates or retrieved-passage counts. "
                "Published figures quoted in RAG may still be reported as document facts, not as "
                "successful SQL calculations. If RAG also found nothing, say that no relevant evidence "
                "was retrieved; do not invent findings or substitute a generic refusal for the data gaps. "
                "When chart_data_unavailable is true, preserve the supported text answer and explicitly "
                "state that no explicit numeric data suitable for the requested chart was found. "
                "When chart_unavailable is true but chart_data_unavailable is false, explain that the "
                "chart could not be prepared or validated and was omitted; do not falsely claim the "
                "report contains no numeric data. "
                "When text_only_fallback is true, rewrite the answer WITHOUT charts after exhausted "
                "chart correction. Use the original evidence to retain or correct supported findings "
                "and quotations, preserve period/population limitations, and disclose the omitted chart. "
                "Do not repeat rejected chart values or unrelated metrics from previous_answer. "
                "Do not promise a chart, refer to absent graphics, or replace supported findings with "
                "a generic failure. The text must pass independent evidence review. "
                "Do not invent or estimate chart values, infer distributions from retrieved examples, "
                "or promise a chart that was not produced. "
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
                "Charts have already been selected before this answer: supplied charts are included "
                "in the SAME response. Describe the provided chart/table directly; do not recommend "
                "that the user create or draw it. If charts is empty, do not claim a chart is present. "
                "One metric compared over two reported periods satisfies a comparison request. "
                "Do not invent a need for a second metric/report/series or call such a comparison "
                "unavailable when the two quoted values are already supplied. "
                "Distinguish unknown coverage from proven omissions: five grouped country rows do "
                "not prove the source contains additional countries, and 16 monthly aggregates do "
                "not prove missing months. A bounded catalog is not proof of a partial sample either. "
                "State the actual queried file/shard and any cap; call unverified wider coverage "
                "unknown, not incomplete. SQL needs no retrieved-passage citations; omit irrelevant "
                "no-passage-citation disclaimers in SQL-only answers. "
                "Respect retrieval_method, truncated and warnings: an overview subset is not a representative "
                "sample or a whole-dataset summary. Ground qualitative statements in the supplied passages. "
                "For cross-source comparisons, explicitly check each source/theme against actual passage text. "
                "A question saying 'the two reports emphasize X' is an unverified user premise, not report "
                "evidence. If only review passages were retrieved, discuss those examples against the "
                "user-specified theme and explicitly state neither report's premise was verified; never "
                "claim that reviews confirm or contradict the reports without report passages. "
                "SQL keyword matches are lexical subsets, not semantic theme prevalence. Sentiment labels "
                "within those subsets do not establish support/contradiction of a theme or report. Do not "
                "rank themes by strength using different keyword sets, match counts or subset positivity. "
                "Distinguish a passage's meaning from its stored sentiment label when they disagree. "
                "If one report or theme is missing, preserve verified findings and name the evidence gap; "
                "do not claim a completed comparison or shared trend without support from both sources. "
                "For separate summaries of unrelated sources, keep each source's findings, population and "
                "time period separate. A failed SQL worker blocks financial/statistical claims from that "
                "worker, not supported report findings or report charts. Weak/truncated evidence permits "
                "cited observations explicitly scoped to the retrieved passages, not whole-market conclusions. "
                "When fewer charts are supported than requested, preserve supported charts and disclose "
                "which requested sections lack data; do not claim all chart data is unavailable. "
                "Contents pages, acknowledgments and repeated footers do not establish consumer findings. "
                "History and planner goals are not verified data. Skipped ingestion records can be empty, "
                "short or duplicate text, not additional customer reviews. "
                "Retrieval warnings describe execution/coverage only; candidate counts and query words "
                "are never evidence of matching review traits. Match review rating/sentiment in metadata "
                "before using a passage as a mismatch example. SQL counts remain valid independently "
                "of missing qualitative examples: preserve verified statistics and disclose the text gap. "
                "When no review passages were retrieved, do not claim customer complaint themes or causes. "
                "A SQL quotation_availability flag, non-null text count or column name is NOT an actual "
                "quotation. Distinguish 'no excerpts were retrieved for this answer' from 'the dataset "
                "contains no review text'; never assert the latter from missing RAG results. If excerpts "
                "are missing, explicitly leave quotation-grounded suggestions unsupported; do not pretend "
                "that the flag supplies them. "
                "Use sql_result.source_datasets to map physical tables in the executed SQL to uploaded "
                "filenames. Trace each aggregate through its CTEs to the actual table; aliases and literal "
                "section labels are not proof of source identity. Never report review-table counts as "
                "report counts, or substitute low ratings for negative sentiment. If a metric's source "
                "label conflicts with its actual table, omit that mislabeled interpretation and disclose "
                "the conflict while retaining independently supported financial totals. "
                "For financial totals plus qualitative reviews/reports, prioritize the requested sales "
                "and profit totals and cited customer needs/trends. Do not turn unsolicited keyword "
                "counts into market risks or pad the answer with unrelated sentiment statistics. Positive "
                "sales/profit totals do not establish available cash, an investment budget or causal ROI. "
                "Still report verified group rates and sample sizes; label any suggested investigation "
                "as a recommendation based on statistics, not a finding from review text. Distinguish the "
                "highest rate from the largest count, and keep source scope and small-sample limitations. "
                "When revising, correct the supplied "
                "previous_answer against current evidence rather than assuming review suggestions are facts.\n"
                + ANSWER_LANGUAGE_PROMPT,
                payload,
                Answer,
            )
            return {"answer": _map_answer_citations(answer.model_dump(), references)}

        async def review(state):
            note(state, "review_evidence", "Reviewing answer, numerical claims and citations...")
            payload = {**evidence(state), "answer": state["answer"], "charts": state.get("charts", [])}
            result = await self.model.structured(
                "Review the actual draft against question and supplied evidence. "
                "Check numerical claims against "
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
                "One report explicitly comparing the same metric over two periods supports a "
                "comparison chart; do not require a second metric or report. Preserve stated periods "
                "and populations; a missing earlier sample size alone is not grounds to reject "
                "an explicitly published comparison if that limitation is honestly disclosed. "
                "Unknown coverage does not prove missing records: returned group counts, monthly "
                "aggregate counts and bounded-catalog warnings do not establish that the source "
                "contains additional countries/months or is an incomplete sample. "
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
                "When sql_unavailable is true, a failed SQL query is NOT grounds to block independently "
                "supported RAG findings or document charts. Require an explicit missing-SQL-data "
                "limitation and omission of unsupported SQL calculations, not a generic refusal. "
                "When chart_data_unavailable is true, approve supported textual findings with an explicit "
                "statement that no suitable explicit numeric chart data was found. Do not require "
                "a chart, assumed values, or SQL confirmation for already quoted report figures. "
                "When chart_unavailable is true but chart_data_unavailable is false, require disclosure "
                "that the chart could not be prepared or validated and was omitted, not a false claim "
                "that the report lacks numbers. When text_only_fallback is true, independently review "
                "the new text against original evidence, not the rejected chart or previous draft. "
                "Do not demand another chart or reject supported text solely because a requested chart "
                "was omitted with this disclosure. Unsupported text, incorrect mappings in the "
                "narrative, invented citations and workspace mismatches must still fail review. "
                "If these disclosures are missing, request a text revision; missing data alone must "
                "not produce status=blocked. Unsupported claims and invalid citations still fail review. "
                "A user premise about report themes is not verified evidence. If report passages are absent, "
                "require an explicit statement that the report claims were not verified and scope discussion "
                "to reviews against the user-specified themes. A generic 'partial coverage' disclaimer does "
                "not justify claiming that reviews reinforce the reports. Keyword matches plus sentiment "
                "labels do not prove semantic support/contradiction; reject theme-strength rankings from "
                "different lexical query sets, even when their counts and percentages are numerically correct. "
                "Weak/truncated retrieval does not invalidate accurate citations from the returned passages. "
                "For separate source summaries, require explicit scope rather than exhaustive coverage. "
                "Fewer charts than requested is a disclosed limitation, not a reason to block otherwise "
                "supported findings or demand invented charts for a failed SQL source. "
                "For any route with SQL rows but no review passages, approve accurate scoped statistics and "
                "clearly labeled statistical recommendations if the missing original-text evidence is "
                "disclosed; do not require nonexistent citations or invented complaint themes. "
                "A quotation-availability flag does not supply quotations, but does not contradict a "
                "clear statement that no actual excerpts were retrieved for this answer. Require that "
                "distinction, not a claim that the source has no quotations. Missing quotations alone "
                "must not repeatedly reject a corrected, honestly limited statistical answer or remove "
                "its valid chart. "
                "Use sql_result.source_datasets and the executed SQL to trace aggregate sources through "
                "CTEs. Reject review counts relabeled as report counts, or low ratings relabeled as "
                "negative sentiment, even if the numeric values appear in SQL output. Require omission "
                "or correction of those interpretations, retaining separately valid financial totals. "
                "Positive sales/profit does not prove cash available to fund improvements or their ROI. "
                "A review_overview uses stored passages, not semantic scores; null similarity is expected. "
                "The record_id fields in rag_result.results ARE citation IDs; require the draft's "
                "citation_ids to identify supporting passages for a review overview. "
                "Require disclosure of truncated coverage, and reject population claims from a bounded subset. "
                "History and planner goals do not establish facts. Ingestion skipped_records does not establish "
                "a count of missing reviews. When charts is empty, chart_issues must be empty; "
                "do not report an already disclosed chart-generation error as a new chart issue. "
                "Return approved, revise or blocked.\n" + ANSWER_LANGUAGE_PROMPT,
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
            inline = {
                citation.lower()
                for text in state["answer"].values()
                if isinstance(text, str)
                for bracket in _CITATION_BRACKET.findall(text)
                for citation in _CITATION_REFERENCE.findall(bracket)
            }
            if inline - {item.lower() for item in allowed}:
                if result.status == "approved":
                    result.status = "revise"
                result.required_changes.append(
                    "Replace unrecognized inline citations with the supporting passage's supplied "
                    "reference, not document_id. Remove any claim without a supporting passage. "
                    "When no passages were returned, do not include passage citations."
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
                update.update(charts=[], chart_feedback=result.chart_issues)
                if not state.get("revision_count") and result.status != "blocked":
                    if result.status == "approved":
                        result.status = "revise"
                        update["review"] = result.model_dump()
                else:
                    update["errors"] = [
                        {
                            "worker": "prepare_charts",
                            "code": "INVALID_CHART",
                            "message": "Charts did not pass evidence review and were omitted: "
                            + "; ".join(result.chart_issues),
                            "retry_count": 0,
                        }
                    ]
            return update

        async def revise(state):
            emit("revision", "Revising the answer and any rejected charts once based on evidence review...")
            return {"revision_count": 1}

        async def text_only(state):
            note(
                state, "generate_text_only",
                "Omitting rejected charts and independently checking a text-only answer...",
            )
            return {"charts": [], "chart_feedback": [], "text_only_fallback": True}

        def review_route(state):
            if (
                state["review"]["chart_issues"]
                and state.get("revision_count")
                and not state.get("text_only_fallback")
                and state["review"]["status"] != "blocked"
            ):
                return "generate_text_only"
            if state["review"]["status"] == "approved":
                return "emit_response"
            if state["review"]["status"] == "revise" and not state.get("revision_count"):
                return "revise"
            return "handle_error"

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
            ("generate_text_only", text_only),
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
        graph.add_edge("direct_llm", "prepare_charts")
        graph.add_edge("rag_search", "aggregate_results")
        graph.add_edge("sql_query", "aggregate_results")
        graph.add_conditional_edges("aggregate_results", aggregate_route)
        graph.add_edge("generate_final_response", "review_evidence")
        graph.add_conditional_edges(
            "prepare_charts",
            lambda s: "emit_response" if s["request_type"] == "FILE_UPLOAD" else "generate_final_response",
        )
        graph.add_conditional_edges("review_evidence", review_route)
        graph.add_edge("revise", "prepare_charts")
        graph.add_edge("generate_text_only", "generate_final_response")
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
