# Module 06 implementation and acceptance report

> 🌐 语言 / Language: **English** | [中文](implementation-report_CN.md)

> **Historical snapshot, not current deployment instructions or a current acceptance result.**
> The status, test totals, blockers and present-tense descriptions below refer to the implementation stages
> recorded here. They are retained as history; do not treat them as the latest source or cloud deployment status.
> In particular, browser/workspace keys and secret-derived owners have since been removed.
> The current Bash path uses Entra database authentication, shared keyless workspaces and A2A peer authentication;
> its sole packaged SQL script initializes the schema without owner columns.
> Use the [module walkthrough](../../readme.md), [CLI deployment guide](cli-deployment.md) and
> [architecture](architecture.md) for current behavior. Record fresh acceptance for the exact revision,
> image digests, provider and deployment being tested; do not reuse the historical pass counts below.
> The synthetic fixtures and fixed SQL totals below belong only to those historical tests.
> The current workshop uses the actual [module-level upload parts](../../sample-data/) and checks results
> against the files actually uploaded; it does not use `agent-src/sample-data`.

**Status when recorded: distributed implementation and local acceptance pass; image and real-cloud acceptance were not complete.**
The prior Windows asyncio startup and Docker engine blockers are resolved. Docker 29.9.2 (Linux)
successfully ran the local PostgreSQL/vector test. Historical local image builds failed during dependency
download with `SSLV3_ALERT_HANDSHAKE_FAILURE` from `files.pythonhosted.org`.
The build entrypoints now use ACR Tasks quick builds (`az acr build`) against an existing registry,
following Module-03's actual build step whose image is reused by Module-04. Local image builds are no
longer the workshop path. Actual ACR runs have not been submitted; cloud build success is not claimed.
No cloud deployment or real cloud model/data-service result is claimed.

## Implementation inventory

Database backends now support `DB_PROVIDER=horizondb` (default) or `postgresql` (Azure PostgreSQL Flexible Server).
All settings use generic `DB_*` / `db_*`, sharing one psycopg repository, SQL and migrations, defaulting to `postgres`.
The generic deployment entry point and PG17 Flexible Server template retain the HorizonDB compatibility entry,
standardize password-free resource manifests, vector allowlisting, TLS and explicit firewall rules, and never
fall back to another backend. Business, A2A and model behavior are unchanged.
Validation for this change is local/offline only; no Azure database or billable resources were created.

| # | Required report item | Result |
|---|---|---|
| 1 | Module 01 discovered | Foundry model/project, APIM and managed identity reused through configuration; no edits |
| 2 | Module 03 discovered | Plain HTML/CSS/JS chat and Responses integration; UI adapted, direct model calls removed from Chat |
| 3 | Architecture | Five separate Agent services, A2A discovery/collaboration, LangGraph inside Orchestrator |
| 4 | Directory structure | Five Agent packages plus shared, migrations, deploy, tests, docs and sample-data |
| 5 | Created files | A2A transport, remote proxies, worker entrypoints, five Dockerfiles, Compose topology, AKS renderer, actual ACA SDK deployment helper and guest bootstrap, image script, tests and sandbox guide |
| 6 | Modified files | Both requested prompts; Module-06 configuration, Orchestrator injection, Chat composition, dependency manifest, packaging and related documentation |
| 7 | Boundary | Agent implementation remains under Module-06/agent-src, with the two requested prompts under Module-06; the root Markdown viewer and its navigation tests also include Module-06 |
| 8 | Graph | Receive, plan, DIRECT or remote workers, aggregation, synthesis, review, one revision, explicit error and response |
| 9 | Blob | Chat stores original; FileRef crosses A2A; Processing reads private Blob directly; local shared directory only in development |
| 10 | HorizonDB | Repository and packaged migration pass against live local PostgreSQL 17/pgvector; Azure HorizonDB itself remains unverified |
| 11 | Processing | PDF/DOCX/TXT/MD/CSV/XLSX/JSON, typed relational rows, token-bounded Unicode-safe chunks, linked review vectors |
| 12 | RAG | Workspace/metadata filters, cosine threshold, up to five source-bearing results, explicit insufficient evidence |
| 13 | SQL | Schema-aware generation, AST gate, bounded read-only query, workspace rewriting, exact results; wire preserves large integers |
| 14 | DIRECT | Verified via graph, A2A five-process API and browser with explicit model fixture |
| 15 | RAG | Verified through remote worker and browser using uploaded synthetic report |
| 16 | SQL | Verified through remote worker and browser; sample France=4000, Germany=3300 |
| 17 | HYBRID | Parallel event-barrier tests pass; five-process and browser synthesis path pass; killed SQL peer produces explicit partial result |
| 18 | Progress | A2A task-status SSE from Processing feeds run events; browser polls Chat, Chat polls Orchestrator over A2A |
| 19 | General model | Foundry Responses adapter remains real production implementation; actual cloud invocation not validated |
| 20 | Embeddings | Foundry batch/dimension validation retained; real cloud invocation not validated |
| 21 | Local setup | venv, editable dev install, .env, PostgreSQL, migration, five native processes or Compose |
| 22 | Azure configuration | Five sandbox URLs, peer/browser secrets, private Blob/HorizonDB, model endpoints, runtime identity and networking |
| 23 | Migration | `python -m shared.database`; dedicated DB and stable vector dimensions required |
| 24 | Start | Each Agent's `app:create_app` on its own port/process; see README table |
| 25 | Test commands | Full pytest, Node UI tests, Ruff, mypy, compileall, package build and deployment artifact checks |
| 26 | Tests executed | All local unit/API/graph/A2A/process tests; actual browser upload and all four modes |
| 27 | Test results | 80 Python passed, 0 skipped with live PostgreSQL enabled; 3 Node UI passed in prior acceptance; no deselected async tests |
| 28 | Static/build | Ruff, formatting, mypy, Python/JS syntax and wheel/sdist checks; historical local build failed; ACR image execution remains unverified |
| 29 | Limits | Single Orchestrator scheduler, no durable in-flight resume, workshop shared identity/key, no RLS/OCR/automatic retention |
| 30 | Next steps | Run the ACR build wrapper with the approved existing registry, verify all five published images, configure cloud resources, perform actual AKS/ACA acceptance |
| 31 | A2A | Official SDK 1.3.0, protocol 1.0 JSON-RPC/SSE, authenticated cards, pinned endpoint/role/skills, typed messages, failed tasks and bounded transient task history |
| 32 | Images/sandboxes | Five Dockerfiles and startup modules; AKS Sandbox/Kata renderer; ACA SDK 0.1.0b4 deployment helper tested against real SDK signatures, plus portal alternative |

Detailed structure, environment variables and commands: [README](../README.md).
Sandbox/image details: [sandbox deployment](sandbox-deployment.md).

## Bash/Bicep/ACA CLI deployment path

- Added [HorizonDB Bicep](../../bicep/horizondb.bicep) and a direct Bash deployment wrapper with automatic ARM validation. They reuse
  Module-01's existing RG/location, provision a PostgreSQL 17 HorizonDB cluster and vector parameter group,
  default to workshop public IPv4 access (`0.0.0.0` - `255.255.255.255`), accept explicit restricted
  firewall ranges, and pass the password through a secure parameter file. Public exposure is intentional
  for this workshop; TLS/authentication remain required.
- Added [Bash ACA deployment](../../deploy-aca.sh), retaining the SDK alternative. It reuses the
  Module-04 group, imports five ACR images using the existing pull identity, creates five Sandboxes,
  securely distributes discovered URLs/configuration, optionally runs the application migration,
  checks database/schema access, waits for five health/card probes and checks a read-only Chat A2A call.
- Bicep MCP compiler **0.48.1**: successful compilation, **zero diagnostics**. Installed Azure CLI Bicep
  **0.44.1** also compiles but has missing-preview-type warnings; the current schema/compiler was used
  for resource-property validation.
- Initial deployment-path run of `tests/deploy-shell.test.sh`: **passed, exit 0** with real **ACA CLI 1.0.0-preview.5 offline manifest
  validation**. Azure/HTTP operations are stubs. Coverage includes argument/configuration rejection,
  explicit context and region reuse, secret-free command arguments/output, protected upload order,
  five-role topology, retry-to-ready, exact failure stages, partial inventories, wrong cards,
  failed A2A calls, nonzero guest exit codes and bounded timeouts.
- Existing deployment/bootstrap/SDK contract tests: **7 passed, exit 0**. Actual A2A SDK card serialization
  matches the Bash readiness predicate. Wheel/sdist include the shell scripts, Bicep and jq validator;
  documentation links and shell LF endings were checked.
- No HorizonDB deployment, image import, paid ACR build or live five-Sandbox validation was performed.
  CLI help/schema checks and stub tests are **not** cloud acceptance. Guest identity, network egress,
  preview availability and actual model/Blob/worker flows remain external acceptance requirements.
- See [the CLI runbook](cli-deployment.md) for executable steps, firewall/identity prerequisites,
  database initialization, statuses, timeouts and cleanup. No Module-01/04 files were changed.
- Deployment flags override environment variables; shared defaults match Modules 01/04 (`IMAGE_TAG=latest`,
  `AUTO_SUSPEND_MINS=15`, existing RG/region/resource naming). The English README now has an equivalent
  [Chinese counterpart](../readme_CN.md); the root Markdown viewer exposes Module-06 and its Agent/runbook pages.

Later lifecycle correction: the initial `15`-minute default above is superseded by `AUTO_SUSPEND_MINS=0`
(disabled) for persistent cooperating Agents. Manual-activation ports do not wake suspended workers.
The optional SDK deployer also disables auto-suspend; this improves availability but incurs idle compute charges.

### Public-access, environment and navigation follow-up verification

- Expanded Bash deployment tests: **passed, exit 0**, covering the exact public IPv4 range, its warning,
  environment/file password precedence, context/resource naming, environment-only deployment, sizing,
  suspension and explicit flag overrides. Cloud operations use stubs; this follow-up did not rerun
  the optional real ACA CLI validator. Ordinary failure cases have a separate timeout budget from the
  deliberate timeout case, which asserts exit code **124**.
- Bash and PowerShell ACR builder tests: **passed, exit 0**, including `latest`, environment tags,
  explicit overrides and failure behavior. Merged Compose configuration resolves all five images
  correctly with both the default and an overridden tag; no containers were started.
- Bicep **0.48.1** compilation: **zero diagnostics**; the compiled firewall default was checked for
  `0.0.0.0` and `255.255.255.255`.
- Run `node --test tests/markdown-viewer.test.cjs` from the repository root:
  **5 passed, exit 0**, covering exact filename casing, both languages, ten Module-06 resource links,
  active selection, unpaired documents and other modules' navigation.
- Live browser checks passed for Chinese/English switching, both Mermaid diagrams, the Chinese RAG
  walkthrough and the CLI runbook without a nonexistent translation switch.
- Compared both READMEs: matching heading structure, **8 code blocks**, **35 table rows** and environment
  identifiers; checked related documentation links and Bash LF endings. Wheel/sdist build passed;
  the sdist includes both READMEs, and deployment assets are packaged.
- These are local/offline checks, not a HorizonDB or five-Sandbox cloud deployment.

## Local acceptance evidence

- ACR build-path update: both Bash and PowerShell wrappers pass Azure-CLI-stub tests (exit code 0)
  for five remote builds, default/custom tags, relative Dockerfile paths, spaced source paths, invalid
  arguments, removed push flags and fail-fast behavior. No real ACR builds were submitted.
  Compose configuration checks pass for five registry-qualified images with no local build definitions;
  a missing `ACR_LOGIN_SERVER` fails explicitly. Seven deployment tests pass. Source-package checks
  include both wrappers and their regression scripts; Shell files retain LF line endings.
  All five Agent README language pairs and 225 relative documentation links were checked.
- Baseline after policy adjustment: **61 passed, 1 skipped**. The previous async/API startup hang no longer occurs.
- Prior expanded suite with sandbox SDK extra installed: **79 passed, 1 skipped**.
- Docker retry: **80 passed, 0 skipped**, exit code 0, with `STUDIO_TEST_POSTGRES=1` and an isolated
  `pgvector/pgvector:pg17` container on a random loopback port. No tests are deselected.
  Live checks cover migration, ingestion, vector retrieval, workspace isolation, exact SQL aggregation,
  duplicate ingestion, persisted run lookup/isolation, database-enforced read-only transactions and
  query timeout followed by successful pool reuse. Disposable containers and their volumes were removed.
- Historical local five-image build script retried twice with `-Registry studio-local -Tag acceptance`; both attempts
  returned exit code 1 while installing the first image's build dependencies. No Agent image completed.
  A separate base-image HTTPS probe confirmed PyPI index and tokenizer storage returned HTTP 200,
  while `files.pythonhosted.org` failed its TLS handshake. Certificate verification was not disabled.
- Five independent OS processes bind distinct loopback ports and use official A2A JSON-RPC/SSE:
  - authenticated discovery for all five cards;
  - browser API -> Chat -> remote Orchestrator -> remote Processing/RAG/SQL;
  - actual file upload to the local adapter and processing via FileRef;
  - DIRECT/RAG/SQL/HYBRID, SQL totals and citations;
  - source/dataset listing;
  - terminate only the fixture SQL process, then verify HYBRID partial status and PEER_UNAVAILABLE.
- Parallel proof: an event-barrier test requires both remote worker requests to enter before either can complete.
- Adversarial cases: forged card endpoint/role/skill/version, incorrect peer credentials, unknown owner,
  cross-workspace worker access, unsupported operation, malformed inputs, missing datasets and peer timeout.
- Large integer regression: A2A round-trip preserves `9007199254740993`, avoiding protobuf double precision loss.
- ACA adapter tests verify the installed SDK signatures, five distinct disk/sandbox operations, HTTPS ports,
  mode-0600 configuration delivery, per-peer URLs, explicit apply gating and secret-free failure inventory.
  Guest bootstrap waits for atomic configuration, drops Linux privileges and execs the designated Agent.
  These are mocked SDK calls, not actual Azure provisioning.
- Integrated browser against the five-process fixture:
  - create workspace; upload synthetic Markdown and financial CSV;
  - see actual extraction/embedding/storage progress;
  - complete DIRECT/RAG/SQL/HYBRID with no UI error;
  - inspect SQL evidence and verify France 4000 / Germany 3300;
  - reload and reconnect: conversation history restored and access key was not persisted.
- Node UI tests: safe text rendering, real event display and explicit failure/retry handling pass.

The browser test initially attempted to inspect a hidden details element with `innerText`; the assertion was
corrected to `textContent`, then exact totals were verified. This was a test inspection issue, not changed SQL.

**Important:** the five-process/browser tests use explicit test-only models and SQLite repositories;
the opt-in PostgreSQL integration test uses the real repository and live PostgreSQL/vector without model calls.
The production entrypoints have
no fixture switch and no silent in-process/SQLite fallback. Local success is not a claim about Foundry quality,
HorizonDB vector compatibility, Azure Blob credentials, container startup, Kata isolation or ACA lifecycle.

## Validation commands

```sh
python -m pytest -q -p no:cacheprovider
node --test tests/ui.test.cjs
node --check chat_agent/static/app.js
python -m ruff check .
python -m ruff format --check .
python -m mypy shared data_processing_agent rag_agent sql_agent orchestrator_agent chat_agent deploy
python -m compileall -q shared chat_agent orchestrator_agent data_processing_agent rag_agent sql_agent deploy
python -m build --no-isolation
```

AKS artifact tests assert five actual Sandbox CRDs, Kata runtime, nonroot image commands, distinct service names,
secret references and NetworkPolicies. They do not replace `kubectl apply --dry-run=server` on the target cluster.
The image-build PowerShell script parses successfully. Wheel/sdist asset checks cover SQL migrations, UI,
per-Agent Dockerfiles and deployment instructions.
Mypy passes for all 30 runtime/deployment Python files on both the Windows host and Linux target.
Compose's merged six-service configuration validates without requiring a running Docker engine.

## Remaining acceptance blockers (do not sign off full cloud acceptance)

| Check | Actual observation | Exact next step |
|---|---|---|
| ACR image builds | Scripts now submit cloud builds and publish to the existing ACR; no actual ACR build has been run. The prior local TLS failure is historical, not evidence about ACR networking. | Log in to the approved subscription, run the five-image wrapper with the existing ACR resource name, record run results/digests, then verify container execution |
| Azure HorizonDB | Local PostgreSQL 17/pgvector test passes; actual Azure endpoint untested | Repeat STUDIO_TEST_POSTGRES=1 with a dedicated authorized Azure test database and required TLS; never use a shared production database |
| Foundry and Azure Blob | No actual endpoints/deployments/runtime credentials configured for this acceptance run | Supply intended test configuration and run upload plus model/embedding paths against it |
| AKS Sandbox | Manifests generated/tested, not applied; no target cluster/namespace approved for deployment | Verify CRD/Kata/identity/network prerequisites; dry-run and apply, then repeat browser flows |
| ACA Sandbox | SDK helper and portal alternative provided; no sandbox created | Configure an existing SandboxGroup and credentials; validate config, explicitly run the Python SDK helper with --apply, then repeat full flows |

The initial package lookup did not include prereleases. A follow-up `pip index versions --pre` found
`azure-containerapps-sandbox==0.1.0b4`; it was declared as an optional dependency, installed, inspected and used
for the actual deployment implementation. The earlier SDK-availability limitation is resolved.

Historical initial-implementation note: existing Git status was captured successfully. The entire Module-06 directory was already untracked, so
`git diff` alone cannot inventory its changes. No tracked file outside Module-06 was changed by this task.
Existing unrelated untracked directories/files were left untouched. No commit or cloud provisioning was performed.
At that time the root README had no Chinese counterpart; bilingual source and module-root READMEs were added later.
The five per-Agent English/Chinese README pairs are synchronized
with the ACR build commands.
