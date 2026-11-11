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

Intentional ordering clarification: generation precedes evidence review so the reviewer can inspect the actual
answer, not only source material. A revision is reviewed again; a second failed review blocks the response.
DIRECT uses its initial answer as the draft without an unnecessary second generation call.
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
