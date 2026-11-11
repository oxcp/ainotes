# Chat Agent: browser entry point

[中文](README_CN.md) | [Module overview](../README.md) | [Orchestrator](../orchestrator_agent/README.md)

## 1. Responsibility and design

Chat is the browser-facing service for Product Launch Studio. It serves the UI, authenticates browser
requests, stores uploaded originals, and forwards business operations to the Orchestrator over A2A.
It does **not** call an LLM or Embedding model, connect to PostgreSQL, run LangGraph, or construct local workers.
Calling it an Agent describes its service role; it is not an autonomous model/tool loop.

The production composition is `FastAPI -> RemoteOrchestrator -> PeerClient`, with a `BlobStore` for uploads.
FastAPI's lifespan owns the proxy and closes its HTTP/storage clients on shutdown.

## 2. Code reading guide

| File / symbol | What to read |
|---|---|
| [app.py](app.py): `create_app()` | Application factory, lifespan, browser routes, errors, static files and optional Chat A2A endpoint |
| [app.py](app.py): `security()` | POST rate/size checks and response security headers |
| [shared/bootstrap.py](../shared/bootstrap.py): `build_service()` | Creates only `RemoteOrchestrator(config, BlobStore(config))` |
| [shared/remote.py](../shared/remote.py): `RemoteOrchestrator` | Converts browser operations into typed Studio operations carried over A2A |
| [shared/storage.py](../shared/storage.py): `BlobStore.upload()` | Validates filename/MIME/size/archive structure, saves the original and returns a checksum-bearing `FileRef` |
| [static/app.js](static/app.js) | `api()` sends keyless browser requests; `monitor()` polls runs; `renderMarkdown()` renders text safely |
| [static/charts.js](static/charts.js) | Validates and renders inline bar/line/pie charts and numeric comparison tables using local SVG/text nodes |
| [static/index.html](static/index.html), [static/style.css](static/style.css) | UI controls and presentation |
| [Dockerfile](Dockerfile) | Image build and the Chat-only startup command |

## 3. Execution paths

### Questions

```text
Browser: POST /api/workspaces/{workspace_id}/chat
  -> security(): enforce request limits
  -> RemoteOrchestrator.start()
  -> A2A operation "chat" on Orchestrator
  <- HTTP 202 with run_id
Browser: GET /api/workspaces/{workspace_id}/runs/{run_id}
  -> A2A operation "run"
  <- progress, answer, evidence, SQL, review and terminal status
```

`Question` in [shared/contracts.py](../shared/contracts.py) carries `conversation_id`, `message`,
`recent_context` and optional retrieval `filters`. The browser polls once per second while a run is
running, with an approximately 11-minute polling deadline. Browser progress uses polling, **not browser SSE**;
A2A between services uses JSON-RPC/SSE.

### Agent-labelled progress

The blue progress lines prefix each server event with its responsible Agent, using the existing
`stage` identifier rather than guessing from message text. Handoffs are distinguished from execution:

```text
[Chat Agent → Orchestrator] Request accepted.
[Orchestrator] Understanding your request and selecting data sources...
[Orchestrator → RAG Agent] Searching uploaded documents...
[Orchestrator → SQL Agent] Querying structured data...
[Orchestrator] Combining evidence and checking worker outcomes...
[Orchestrator] Reviewing answer, numerical claims and citations...
```

Upload extraction, chunking, embedding and storage are labelled `[Data Processing Agent]`.
Direct model responses, chart preparation and evidence review belong to the Orchestrator, not separate
Agents. Browser submission is labelled `[Chat UI → Chat Agent]`; the accepted handoff appears only after
the server returns a run ID. Old or unknown stages remain visible as `[Workflow]` instead of inventing an
Agent. This presentation-only change preserves event ordering, polling, automatic scrolling and error
messages, without extra model calls or changes to the A2A protocol or persisted run format.

### Uploads

`upload()` reads at most `MAX_UPLOAD_BYTES + 1` bytes. The remote proxy first authorizes the workspace,
then stores the original in local storage or private Azure Blob, and sends `register_upload` with a
`FileRef` to the Orchestrator. File bytes do not travel inside the A2A request.
The [Processing Agent](../data_processing_agent/README.md) later reads the original independently.
Saving Blob and registering the database record is not a distributed transaction; failed registration
or duplicate uploads can leave unused originals.

### UI state

The page heading and browser tab title are **Agent Host Workshop - Module 06**.
The heading, Session controls and upload controls stay pinned together at the top while the conversation
scrolls. On short screens this region is limited to half the viewport and scrolls internally so controls
remain reachable without covering the composer. The public-access and sequential-upload notices are
omitted from the toolbar; this does not change access permissions, multi-file upload or retry behavior.

Retryable status-poll failures reconnect to the same run up to three times (1/2/3-second delays,
within the run deadline). File POSTs are not automatically repeated. If reconnecting fails, keep the
page open and use **Retry last request**: completed queue entries are skipped and an accepted run ID
is polled again. A transport error does not prove ingestion failed; inspect persisted file/run status.
Refresh for new UI assets only after the queue finishes, because selected files/queue state are in memory.

`sessionStorage` stores the conversation ID and the last 30 displayed messages per workspace. The UI
sends at most six recent messages, each truncated to 3,000 characters, as model context.
The access key is not written to this history. Clearing history clears the browser session history,
not the server's data. Reloaded history is browser-local; it is not reconstructed from database runs.
Rendering uses `textContent` with basic headings/code blocks, not arbitrary HTML or a full Markdown engine.

### Inline charts

Ask “Show total profit by country as a bar chart and data table.” AI may choose a suitable visualization or
follow explicit bar/line/pie/table requests. The Orchestrator selects source cells with `ChartSelection`,
resolves server-owned values to `ChartSpec`, and checks semantics during evidence review.
SQL/HYBRID charts use actual query rows; explicitly requested RAG charts can also use numbers anchored
to retrieved document quotations, not just numeric metadata. No need to list the numbers in your question.
Expand **Chart sources** to inspect filenames, pages, record IDs and original quotations.
The server validates quoted numbers, and evidence review checks units, periods, scope and comparability.
Document pies require an explicit complete partition; retrieval counts are never dataset totals.
Upload charts describe ingestion counts, not business metrics; ask a follow-up analysis question.
Explicit requests with unsuitable/missing chart data show `CHART_DATA_UNAVAILABLE` and retain the answer.
For a grouped before/after bar chart, provide one explicit percentage comparison per line, such as
`Gen AI shopping: 20% -> 24%`. The current request is parsed server-side and captioned as user-provided
data, so empty SQL results do not prevent rendering. Both series appear side by side for each metric.
This does not treat arbitrary report prose or conversation history as verified numeric chart data.

The run's optional `charts` array persists in the existing run JSON. Each has `kind`, `title`, `source`,
`label_column`, `labels` and `series` (`name`, `values`). Limits are four charts, four series, 40 rows,
200 characters per label and finite values within ±10^15. Pie needs one nonnegative, positive-sum SQL
series and valid parts-of-whole semantics. The UI validates again before rendering untrusted persisted data.
Malformed charts show `INVALID_CHART` without discarding the answer; chart-generation failures also show
explicit errors. No model HTML/JS, external chart library or CDN is executed.

Responsive SVG has accessible labels, hover details, source/subset captions and a scrollable text-only
data table. History saves chart specs and chart errors alongside message text; reconnect to the same
workspace after refresh to re-render them in the same tab. Chart-free old history remains compatible.

## 4. Interfaces and trust boundaries

| HTTP interface | Purpose |
|---|---|
| `GET /`, `GET /static/...` | Browser UI and assets |
| `GET /health` | Process liveness only |
| `POST /api/workspaces`, `GET /api/workspaces` | Create/list workspaces |
| `GET /api/workspaces/{workspace_id}` | Check existence/read a workspace |
| `POST /api/workspaces/{workspace_id}/files` | Multipart upload: `file`, `conversation_id`; returns 202 |
| `GET /api/workspaces/{workspace_id}/files`, `GET /api/workspaces/{workspace_id}/sources` | List documents |
| `GET /api/workspaces/{workspace_id}/datasets` | List structured datasets |
| `GET /api/workspaces/{workspace_id}/files/{file_id}/status` | Read processing status |
| `POST /api/workspaces/{workspace_id}/chat` | Start a question workflow; returns 202 |
| `GET /api/workspaces/{workspace_id}/runs/{run_id}` | Poll a business run |

`/api` is keyless; anyone with the Chat URL can access all workspaces in the configured database.
This is a shared workshop, not per-user login. POST rate limiting is process-local and defaults
to 60 requests/minute; POSTs require bounded `Content-Length`. Errors use
`code`, `message`, `request_id`, `retryable` and `details`.

When `A2A_API_KEY` is configured, Chat also publishes `/.well-known/agent-card.json` and `POST /a2a`
with skill `studio`. These require the separate peer key. The Chat peer dispatcher permits workspace,
listing, chat and run operations, but not `register_upload`; binary upload is the browser HTTP path.
See [shared/a2a_transport.py](../shared/a2a_transport.py) for card validation, task events and the Studio
JSON envelope. Never put the peer key in the browser.

## 5. Configuration, startup and image

Run the following from the module's **agent-src root**, not this package directory. First follow the
[root setup](../README.md), configure [.env.example](../.env.example) as `.env`, migrate the database,
and start the other services in separate terminals.

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8080"
python -m uvicorn chat_agent.app:create_app --factory --host 127.0.0.1 --port 8080
```

Use the shared `A2A_API_KEY` (at least 24 characters) and
`ORCHESTRATOR_URL` (local default `http://127.0.0.1:8081`). Configure `BLOB_BACKEND` and either
`LOCAL_BLOB_PATH` or `AZURE_STORAGE_ACCOUNT_URL`. Azure storage uses the private `data` container.
Local Chat and Processing must share the same originals directory/volume.
The common `Settings` schema still requires DB/model values even though Chat does not create those clients.

```powershell
az acr build --registry myregistry --image studio-chat:workshop --file chat_agent/Dockerfile --platform linux .
```

This runs an ACR Tasks quick build in the existing ACR named `myregistry` and automatically publishes the image;
replace the name with your workshop ACR resource name, not its login-server hostname. Azure CLI login and
build permissions are required; local Docker is not. Build all five roles using the scripts in the deployment guide.
The build context must include the shared packages. The image starts only Chat, runs as UID 10001 and
listens on container port 8080. For Compose, AKS Kata Sandbox or ACA Sandbox, follow the
[deployment guide (English/Chinese)](../docs/sandbox-deployment.md); use peer-reachable URLs, not another container's loopback.
Host Azure CLI login is not automatically inherited by containers. `/health` does not verify dependencies.

## 6. Tests and current limits

From the same root, with development dependencies installed:

```powershell
python -m pytest -q tests\unit\test_charts.py tests\integration\test_api.py tests\integration\test_a2a.py
node --test tests\ui.test.cjs
```

These cover browser contracts, authentication/errors, uploads, remote routing and safe UI rendering.
Chart tests exercise the production JSON-output parser with mocked model responses, source validation,
run persistence/cache eviction, malformed specs, XSS-like labels, history and ordinary chat.
For offline browser testing only, run the following from the agent-src root:

```powershell
python -m uvicorn tests.chart_runtime:create_chart_test_app --factory --host 127.0.0.1 --port 8096
```

Use the fixture key
`test-only-access-key-12345678`, upload a CSV with `country,profit` columns, and ask about profit. This
explicit test harness mocks AI/repository dependencies and displays all four chart types; it is not production
configuration or evidence of model quality. Stop the server after testing.
The integration tests inject test models/repositories; they do not prove live Foundry/Blob connectivity.
The UI retry repeats the last action; an upload queue resumes polling accepted runs and skips its
completed entries, but the queue itself is not durable across page reloads. There is no production
multi-user identity model or automatic Blob cleanup. See the [acceptance report](../docs/implementation-report.md)
for the distinction between local tests, image execution and cloud acceptance.
