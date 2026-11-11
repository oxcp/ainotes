# Orchestrator Agent: planning and workflow execution

[中文](README_CN.md) | [Module overview](../README.md) | [Chat](../chat_agent/README.md)

## 1. Responsibility and design

The Orchestrator owns workspace authorization, upload registration, question routing, worker coordination,
answer synthesis/review and business-run persistence. It uses **LangGraph `StateGraph` internally**,
**A2A for remote workers**, and **OpenAI SDK through `Foundry` for model calls**.
It does not use LangChain Agent APIs or Microsoft Agent Framework.

A graph node is a step, not necessarily an independently hosted Agent: planning, aggregation and review
execute here; Processing, RAG and SQL execute in their own services. Production construction injects
`RemoteDataProcessing`, `RemoteRag` and `RemoteSQL`, not local worker implementations.

## 2. Code reading guide

| File / symbol | What it implements |
|---|---|
| [app.py](app.py): `create_app()` | Selects role `orchestrator` in the shared application factory |
| [shared/agent_service.py](../shared/agent_service.py): `create_agent_app()`, `dispatch_studio()` | Builds repository/model/Blob and remote proxies; validates and dispatches peer operations |
| [agent.py](agent.py): `State` | Graph state: request IDs, question/file, plan, worker results, answer, charts, review and errors |
| [agent.py](agent.py): `build_graph()` | Nodes, conditional routing, parallel branches and bounded revision |
| [agent.py](agent.py): `start()`, `execute()`, `get_run()` | Background scheduling, progress, terminal status, persistence and lookup |
| [shared/remote.py](../shared/remote.py) | Remote worker proxies and Processing progress forwarding |
| [shared/models.py](../shared/models.py): `Foundry.structured()` | Responses API call, JSON output and Pydantic validation |
| [shared/database.py](../shared/database.py) | Workspace existence checks, document registration, catalog and persisted runs |
| [Dockerfile](Dockerfile) | Orchestrator-only process entrypoint |

`State.errors` uses `Annotated[list[dict], operator.add]`: parallel nodes append errors rather than
overwriting one another. Worker results occupy separate `rag_result` and `sql_result` keys.

## 3. Graph and execution logic

```text
START -> receive_request
  FILE_UPLOAD -> process_uploaded_file -> prepare_charts -> emit_response -> END
  QUESTION -> classify_and_plan
    DIRECT -> direct_llm ----------------------+
    RAG    -> rag_search -> aggregate_results -+-> generate_final_response
    SQL    -> sql_query  -> aggregate_results -+       -> prepare_charts -> review_evidence
    HYBRID -> [rag_search || sql_query]         |            approved -> emit_response
                  -> aggregate_results -------+            revise   -> revise -> generate_final_response
                                                           blocked  -> handle_error -> emit_response
```

- **Receive:** check workspace existence through `Repository.workspace()`.
- **Upload:** `register_upload()` checks workspace and expected Blob URI, registers the checksum-based
  document, and schedules Processing with the canonical `FileRef`. The distributed upload stores the
  original in Chat; the local `upload()` helper is not the production Chat upload path.
- **Plan:** ask the general model for a validated `Plan`: `DIRECT`, `RAG`, `SQL` or `HYBRID`, plus
  independent `rag_goal` / `sql_goal`. Uploads bypass model planning.
- **Dispatch:** DIRECT calls the general model without querying workspace evidence. RAG/SQL call their
  remote workers. HYBRID fans out both independent branches in the graph before aggregation.
- **Timeouts:** each read worker uses `WORKER_TIMEOUT` (default 120 seconds); `TimeoutError` gets one
  retry. Other failures become explicit worker errors, not invented results. Upload processing is not
  retried by this worker loop.
- **Aggregate/generate:** if neither worker result exists, route to `handle_error`. Otherwise synthesize
  evidence, calculated facts, interpretation, recommendations and limitations. DIRECT reuses its initial
  draft on the first pass instead of making a second generation call.
- **Charts:** `prepare_charts` uses shared `ChartSelection` source/column/row references and resolves actual
  SQL cells, numeric RAG metadata or ingestion counts into bounded `ChartSpec` objects. It skips the model
  for chart-free/text-only sources, times out at `WORKER_TIMEOUT` without retry, and preserves reviewed text on
  explicit chart errors. Upload titles are server-owned ingestion summaries; no business statistics are inferred.
  Invalid selections get one correction with the validation error. SQL long-form groups can select
  `series_column` to pivot exact cells into up to four series; duplicate/incomplete cells are rejected,
  never filled with invented zeroes. Null category labels display as `(missing)`. Valid charts are retained
  during text-only revision. Monthly currency trends and profit margin use separate axes/charts.
  Ratio-like column names (`margin`, `ratio`, `rate`, `pct`, `percent`, `percentage`, or `%`) cannot
  share bar/line axes with other measures. SQL-backed review charts do not extract statistics from
  individual review prose.
- **Review:** the model checks the actual draft and chart semantics. Chart-only problems in `chart_issues`
  remove charts and produce `INVALID_CHART` while preserving otherwise valid text. Code additionally requires
  correction of citation IDs absent from RAG results and blocks evidence from another workspace.
  At most one revision is allowed; revision regenerates the
  answer with review feedback, not the worker queries. Another non-approved review ends in an error answer.

An empty `RagResult` is still a result: insufficient retrieval must be disclosed, but is not automatically
a transport failure. A successful worker can support a partial answer when the other worker fails, provided
review approves it. Model review is not a deterministic proof that every numerical statement is correct.

## 4. A2A contract, progress and persistence

The Agent Card advertises skill `studio`. `POST /a2a` accepts Studio operations through the shared
`PeerRequest(operation, arguments)` contract:

| Operations | Required arguments |
|---|---|
| `workspaces`, `create_workspace` | None for listing; `name` for creation |
| `workspace`, `files`, `sources`, `datasets` | `workspace` |
| `file_status`, `run` | `workspace` plus `file_id` or `run_id` |
| `chat` | `workspace`, `conversation`, structured `question` |
| `register_upload` | `workspace`, `conversation`, `file` |

These are operations inside A2A messages, **not separate REST routes**. Discovery and A2A requests require
`A2A_API_KEY`; workspaces are not bound to a key-derived owner.
Peer URLs come from operator configuration; cards are checked for role, skills, endpoint and protocol.

`start()` returns immediately with `request_id`, `run_id` and `status=running`. This completes the A2A
submission task, **not the business workflow**. Chat polls the separate `run` operation until that workflow
finishes. Processing's A2A status events feed the business run's bounded progress list.

`execute()` applies `REQUEST_TIMEOUT` (default 600 seconds) and graph recursion limit 24.
It keeps the last 100 progress events, determines `completed` / `partial` / `failed`, then calls
`Repository.save_run()`. Terminal status is exposed only after persistence succeeds; a save failure becomes
`RUN_PERSIST_FAILED`. `get_run()` checks memory first, then the database, always after workspace authorization.
There are at most four active workflows and a bounded run cache (`MAX_RUNS`, default 200).
The optional `charts` array is stored in the same run JSON and returned by `get_run()` after cache eviction.
No database migration is needed; the [Chat UI](../chat_agent/README.md) also saves chart specs in local history.

## 5. Configuration, startup and image

Run from the module's **agent-src root**, after [root setup](../README.md), `.env` configuration and migration.
Start the three workers separately. Use the same A2A peer key across services, with at least
24 characters. Browser APIs require no key.

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8081"
python -m uvicorn orchestrator_agent.app:create_app --factory --host 127.0.0.1 --port 8081
```

Configure `DATA_PROCESSING_URL`, `RAG_URL`, `SQL_URL` (local ports 8082, 8083, 8084), the `DB_*`
database settings, model endpoint/deployment settings and the same Blob location used by Chat/Processing.
`DB_PROVIDER=horizondb` (default) or `postgresql` selects HorizonDB / Azure PostgreSQL Flexible Server.
Both share one psycopg repository and default to `postgres`; all five Agents must agree.
`Foundry.structured()` uses `AsyncOpenAI.responses.create()`, Entra authentication and schema validation;
endpoint selection and the shared required fields are in [config.py](../shared/config.py) and
[.env.example](../.env.example). This Agent uses the general model, not Embedding, during normal workflows.

```powershell
az acr build --registry myregistry --image studio-orchestrator:workshop --file orchestrator_agent/Dockerfile --platform linux .
```

This runs an ACR Tasks quick build in the existing ACR named `myregistry` and automatically publishes the image;
replace the name with your workshop ACR resource name, not its login-server hostname. Azure CLI login and
build permissions are required; local Docker is not. Build all five roles using the scripts in the deployment guide.
The root build context includes shared code; the image runs only this role as UID 10001 on container port
8080. Follow the [deployment guide (English/Chinese)](../docs/sandbox-deployment.md) for Compose/AKS/ACA, peer-reachable URLs
and runtime credentials. Host Azure CLI login is not automatically inherited by containers.
`/health` is process liveness, not proof of database, model or peer readiness.

## 6. Tests and current limits

```powershell
python -m pytest -q tests\unit\test_orchestrator.py tests\unit\test_a2a_transport.py tests\integration\test_a2a.py tests\integration\test_processes.py
```

Run from the same root with development dependencies installed. Tests cover four routes, remote parallelism,
partial failure, timeout retry, revision bounds, citation/workspace checks and five-process collaboration.
Model calls in these tests use explicit fixtures, not real Foundry.

This is a single-scheduler workshop design: persisted completed runs survive restarts, but in-flight tasks
and A2A task history are not durably resumed. There is no distributed job queue, multi-replica scheduler,
explicit A2A cancellation or automatic sandbox wake-up. Shutdown cancels active local workflows and closes
resources. See the [acceptance report](../docs/implementation-report.md) for actual runtime/cloud validation.
