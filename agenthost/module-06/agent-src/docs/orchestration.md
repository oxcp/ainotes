# Orchestration

> 🌐 语言 / Language: **English** | [中文](orchestration_CN.md)

Typed LangGraph state holds IDs, question/recent context, file references, validated plan, bounded worker results,
errors, draft answer, bounded chart specs, review and revision count. It never holds original file bytes or entire documents.

| Node | Responsibility |
|---|---|
| receive_request | Verify workspace exists |
| classify_and_plan | Model chooses DIRECT/RAG/SQL/HYBRID; server builds dependency plan |
| direct_llm | General or creative answer without data retrieval |
| process_uploaded_file | Run deterministic ingestion |
| rag_search / sql_query | Independent workers; one timeout retry for safe reads |
| aggregate_results | Superstep fan-in; retain partial results and explicit worker errors |
| generate_final_response | Synthesize polished answer with facts, evidence, interpretation and recommendations |
| prepare_charts | Build bounded chart sources, optionally extract quotation-anchored document values, and validate selected charts |
| review_evidence | Review actual draft, calculations, citations, conflicts and unsupported claims |
| revise | At most one revision |
| handle_error | Return explicit inability to produce a verified answer |
| emit_response | Finish the run |

HYBRID conditional fan-out schedules RAG and SQL in the same LangGraph superstep. Both flow to aggregation in the
next superstep. Local graph and remote A2A event-barrier tests cover this parallel scheduling.
Each production worker node uses an A2A client; the LangGraph state stays inside the Orchestrator sandbox.
The planner sees the question, recent context and current file/dataset inventory. Agent Cards validate
configured peers; they are not a dynamically discovered tool catalog for the planner.
The displayed `tasks`/`depends_on` plan describes fixed graph branches, not an arbitrary executable DAG.

The planning prompt chooses the smallest necessary worker set by evidence needs, not file format.
Contrasting disappointing and better-than-expected reviews with quotations is RAG, even across CSV shards;
source scope and citations do not justify SQL. Explicit field filters or sentiment counts alone use SQL.
HYBRID requires a distinct structured query plus retrieved qualitative evidence, such as sentiment
percentages accompanied by review quotations. The prompt requires both needs in the route reason and
includes contrastive examples; this is model guidance, not a deterministic routing guarantee.
Existing deployments must load the updated Orchestrator code to use the revised prompt.

Published percentages and before/after figures in a report remain RAG evidence, even when a chart is
requested: the downstream chart stage extracts quotation-anchored values without requiring SQL.
The planner must not invent a structured counterpart to a PDF or substitute unrelated review/sales
tables for the report's survey metrics. For example, charting the Capgemini report's stated Gen AI
purchase percentages is RAG with `chart_intent=requested`; combining report findings with actual
Financial Sample aggregates is HYBRID. Explicit requests for missing structured sources retain that
scope so the worker reports the limitation instead of querying unrelated data.

Intentional ordering clarification: generation precedes evidence review so the reviewer can inspect the actual
answer, not only source material. A revision is reviewed again; a second failed review blocks the response.
DIRECT uses its initial answer as the draft without an unnecessary second generation call.
For synthesis only, retrieved passages use request-local short references (`R1`, `R2`, ...), with
document/workspace IDs omitted from that view. The server resolves exact references in `citation_ids`
and bracketed text back to original record IDs before chart selection and evidence review. Revisions
reuse the same mapping; persisted evidence and public response contracts still use original IDs.
Unknown references are not guessed, dropped or mapped to document IDs: they fail citation checks,
including inline citations when retrieval returned no passages. Valid IDs do not bypass factual or
workspace review, and the one-revision limit remains unchanged.
Workers receive the full current request alongside the planner goal so an incomplete goal does not
erase requested sources or predicates. If the combined text exceeds the 4,000-character worker limit,
the original request is kept intact and goal omission is logged; conversation history is not forwarded.
For reports-versus-reviews analysis, planning/retrieval prompts request both report evidence and review
examples. Without report passages, synthesis/review must explicitly leave the report premise unverified,
not claim the reviews confirm it. Keyword counts and stored sentiment labels are not semantic agreement
or a valid basis for ranking theme strength. The answer should follow the current user's language.
Statistics accompanying a text-first comparison do not make a chart explicit. Chart selection excludes
conversation history; correction receives the rejected selection plus specific invalid/available columns.
Wide summaries are not silently transposed into invented columns; unsupported selections still fail.
`prepare_charts` runs between generation and review, or after file processing for ingestion-only summaries.
Sources include actual SQL rows, ingestion counts, numeric RAG metadata, quotation-anchored document values
and explicit before/after percentages in the current user request. For document charts, the model selects
numeric text and occurrence anchors; the server verifies them against retrieved passages and resolves the
values. It does not accept invented numbers or infer missing chart labels from lost PDF layout.
User-supplied comparisons are labeled as such, not independently verified report facts.
When appropriate, document extraction runs before deciding whether chartable data is available;
an explicit chart request without usable data produces `CHART_DATA_UNAVAILABLE`.
Long-form SQL can be pivoted by `series_column`; duplicate/incomplete cells are rejected rather than filled
with invented zeros. Currency and ratio series must not share a bar/line axis.
For group-rate comparisons with sample sizes, the chart prompt selects the actual rate series separately
from a count table/chart; count bars must not be titled as rates. Decimal strings remain valid numeric
cells, and fractions retain their 0–1 scale unless SQL explicitly returns percentages.
When review retrieval is empty but SQL succeeds, generation and review are instructed to preserve scoped
statistics, disclose missing quotations, and label suggested investigations as statistical recommendations,
not observed complaint themes. Unsupported claims still fail review.
Conversely, SQL failure does not invalidate independently supported report observations or document charts.
For separate multi-source summaries, prompts preserve each source's scope and select fewer charts when
the requested count cannot be supported, disclosing missing sections rather than discarding all charts.
Weak/truncated retrieval permits cited, passage-scoped observations, not whole-market conclusions.
Worker errors retain safe `StudioError` messages; unexpected exception details are never exposed.
Chart failures/timeouts are explicit partial-run errors rather than losing the answer. Review reports chart-only
semantic issues in `chart_issues`; those charts are removed without blocking valid text.
Specs are bounded to four charts, four series and 40 rows each; completed run JSON and browser-local
history retain them. See [Chat charts](../chat_agent/README.md#inline-charts).

Progress is emitted by actual nodes and ingestion stages, retrieved by one-second bounded polling. No fake timers.
Limits: 24 graph steps, one safe-read retry, one revision, four active workflows, 100 progress events/run,
`MAX_RUNS` in-memory runs (default 200), configured request/worker/query timeouts. There are no retries of SQL mutations (none allowed).

Terminal run status is exposed only after persistence succeeds. Completed results are persisted to agent_runs
and are read from the database when absent from process memory. Verify this restart behavior against the target
database during deployment acceptance; in-progress graph checkpoint recovery is not implemented.
The Repository `save_run`/`run` boundary is the persistence interface for a future
durable scheduler/checkpointer. A process crash can abandon an in-flight run; reuploading a completed checksum
reuses its processing record. A stopped process is not advertised as a resumable workflow engine.

Chat's workspace/chat/upload/run operations cross the same A2A boundary. Browser file bytes go into private Blob
in the Chat process; only a validated FileRef crosses to the Orchestrator and Processing service.
Processing task-status updates are forwarded into the Orchestrator's run event list.
An unreachable worker produces PEER_UNAVAILABLE, not an in-process fallback. Acceptance should verify a
HYBRID partial/error outcome when SQL is stopped, with available RAG evidence retained and no fabricated SQL result.
Transient A2A tasks use bounded in-memory history per service; they are not durable LangGraph checkpoints.
