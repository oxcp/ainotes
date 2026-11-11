# Architecture

> 🌐 语言 / Language: **English** | [中文](architecture_CN.md)

For the consolidated module overview, deployment and demo steps, start with the
[Module 6: Multi-Agent Business Scenarios walkthrough](../../readme.md). This page describes the system-wide architecture;
the individual [Chat](../chat_agent/README.md), [Orchestrator](../orchestrator_agent/README.md),
[Data Processing](../data_processing_agent/README.md), [RAG](../rag_agent/README.md) and
[SQL](../sql_agent/README.md) READMEs describe each Agent's implementation.

Python package names use underscores instead of the suggested hyphens so they are directly importable.
Each worker exposes a typed operation through standard A2A 1.0 and has no dependency on another worker.
The Chat API depends only on the Orchestrator facade and the shared composition root. It never calls models,
workers or database repositories directly. Production Chat constructs a remote Orchestrator client plus Blob adapter;
production Orchestrator constructs remote Processing/RAG/SQL clients, never local workers.

## Boundaries

- Experience: Chat's FastAPI and browser UI in its own sandbox; no model credentials in the browser.
- Control plane: separate LangGraph Orchestrator sandbox; checks workspace existence and starts bounded background runs.
- Workers: typed Data Processing, RAG and SQL results validated by Pydantic.
- Data plane: private Blob originals; HorizonDB / Azure PostgreSQL Flexible Server metadata, relational tables and vectors.

`DB_PROVIDER=horizondb` (default) or `postgresql` selects the database resource. One shared psycopg repository
uses generic `DB_*` settings and identical migrations, defaulting to `postgres`, with unchanged Agent/A2A/model logic.
- Models: Foundry OpenAI v1 Responses and Embeddings through the existing Module-01 APIM.
  Module-06 adds an embeddings operation/backend; cloud ingestion and queries never fall back to a direct account endpoint.

The UI/CSS and message flow were adapted from Module-03 `app/portal.html`: dark theme, right-aligned user messages,
left-aligned answers, Enter-to-send and disabled controls while waiting. Its stdlib HTTP server and direct model
calls were replaced by FastAPI and the Orchestrator. Module-03 was not modified.

Module-01 provides a Foundry account/project, general model deployment and APIM AI gateway with a UAMI. Its defaults
include project `maf-agent-prj` and model `gpt-5.4-mini`; this module requires actual deployment names via environment
variables instead of hardcoding them. The Module-06 `models` stage provisions the account model and APIM
embedding children without changing Responses, parent resources or IAM. The operation validates the Agent
UAMI `oid` and `ai.azure.com` audience before inherited auth, then uses APIM's existing system identity
to call the account OpenAI endpoint with `ai.azure.com` backend auth. The attached UAMI is not selected
as the backend identity. Local-only flows may explicitly configure a direct endpoint/scope.

Local: PostgreSQL 17 + pgvector in Compose; filesystem originals; real Foundry models. Tests explicitly inject a
SQLite-backed repository and deterministic model double. Test doubles are not selectable in the production app.
Azure: the selected HorizonDB/PostgreSQL backend, Blob SDK with DefaultAzureCredential, and Foundry
request authentication through Entra credentials; the credential implementation manages token caching/refresh.
All five services have independent images and entrypoints. AKS Sandbox uses Kata isolation; ACA uses
SandboxGroup disk images and individual micro-VMs. See [sandbox deployment](sandbox-deployment.md).

## Discovery and communication

The official A2A SDK serves authenticated Agent Cards and JSON-RPC/SSE endpoints. Peer base URLs are configured
by deployment configuration; the primary Bash path fills them from actual sandbox ingress URLs.
The first peer call fetches and verifies the card, then caches the client. Discovery validates role name,
skills, streaming support, protocol 1.0 and the exact endpoint; it does not search for arbitrary new Agents.
No card may redirect credentials to a different address. A2A Data Parts contain a versioned-by-application
Studio JSON string envelope to avoid protobuf double conversion of exact SQL integers.
Worker outputs become task artifacts, progress becomes task status updates, and failures become failed tasks
with safe structured errors. A2A_API_KEY authenticates peers independently of workspace data.
The workshop uses shared workspaces and a shared peer key, not cross-organization identity federation.
Cloud workers read Blob directly, not shared host paths. Independent process tests use real HTTP/SSE and shared
test storage; they do not prove micro-VM isolation or cloud-service connectivity.

Browser APIs are keyless: anyone with the Chat URL can access this deployment's workspaces and data.
Each workspace API validates that the workspace exists. Worker repositories include workspace
predicates; generated SQL is rewritten so each approved physical table is a workspace-filtered subquery.
This is a single-operator workshop authorization model, not production multi-user identity.

## Configuration and initialization

The primary Bash path generates common settings from Module-01 resources, or reads an explicit `ACA_COMMON`
input. It merges database/model/identity outputs and the peer key into the five-role `aca-config.json`.
For each sandbox, deployment selects that role's settings, adds the actual URLs and delivers a protected
`/app/.local/studio-runtime.json`. `shared.sandbox_bootstrap` loads it into the process environment before
starting the Agent; `shared.config.Settings` validates the values. `.env.example` is a reference template,
not the cloud runtime input. A local `.env` remains supported for development.

The runtime JSON is not an Agent Card: it contains private configuration and the peer key. The card is
generated from the role's code-defined skills and `A2A_PUBLIC_URL`, advertises the `/a2a` endpoint and
authentication scheme, and never includes the key value.
With `--migrate`, the Bash script executes the shared initialization code once in the Orchestrator sandbox
before activating the services. [001_initial.sql](../migrations/001_initial.sql) creates the current schema
without workspace key/owner columns; it does not upgrade existing legacy table definitions.
