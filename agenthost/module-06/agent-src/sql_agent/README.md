# SQL Agent: bounded natural-language-to-SQL execution

[中文](README_CN.md) | [Module overview](../README.md) | [Orchestrator](../orchestrator_agent/README.md)

## 1. Responsibility and design

SQL turns a question into one constrained SQL proposal, validates and scopes that SQL, executes it against
the workspace's structured datasets and returns the actual rows. **The model proposes SQL; the database
performs the calculation.** The worker does not ask an LLM to guess totals or write the final narrative.
The [Orchestrator](../orchestrator_agent/README.md) combines the SQL result with other evidence and reviews
the final answer.

The worker calls a general model through the shared OpenAI SDK adapter. It does not use Embedding,
LangChain SQL Agent/toolkit, Microsoft Agent Framework or its own LangGraph.
This is a fixed proposal-validation-execution pipeline, not an autonomous SQL exploration/repair loop.

## 2. Code reading guide

| File / symbol | What it implements |
|---|---|
| [app.py](app.py): `create_app()` | Selects role `sql` in the shared service factory |
| [agent.py](agent.py): `SQLAgent.run()` | Load schema, request `SQLProposal`, validate, execute, log and return `SQLResult` |
| [shared/agent_service.py](../shared/agent_service.py) | Validate A2A arguments and workspace existence before calling the worker |
| [shared/remote.py](../shared/remote.py): `RemoteSQL.run()` | Orchestrator-side remote query proxy |
| [shared/models.py](../shared/models.py): `Foundry.structured()` | Responses API and Pydantic output validation |
| [shared/security.py](../shared/security.py): `validate_sql()` | PostgreSQL AST checks, function/table allowlists, workspace rewrite and limit |
| [shared/database.py](../shared/database.py): `catalog()`, `query()` | Available dataset schema and read-only bounded query execution |
| [shared/contracts.py](../shared/contracts.py): `SQLProposal`, `SQLResult` | Proposal and result contracts |
| [Dockerfile](Dockerfile) | SQL-only image entrypoint |

## 3. Execution logic and safety checks

```text
Orchestrator -> RemoteSQL.run() -> A2A "query"
  -> validate workspace exists
  -> Repository.catalog(workspace)
  -> Foundry.structured(question + catalog, SQLProposal)
  -> validate_sql(): AST gate + workspace rewrite + LIMIT
  -> Repository.query(): read-only transaction + statement timeout
  <- SQLResult with executed SQL and actual rows
```

### Schema and generation

`catalog()` returns up to 12 workspace datasets with their table names, column descriptions and row counts.
An empty catalog raises `NO_DATASET` before any model call. The model receives the question and catalog,
not an unrestricted database browser. It must return a `SQLProposal` containing SQL of at most 8,000 characters.
`Foundry.structured()` uses `AsyncOpenAI.responses.create()`, JSON output and Pydantic validation.
Monthly trend generation requests a unique year-month label, weighted profit margin
(`SUM(profit)/NULLIF(SUM(sales),0)`) and consecutive-month comparisons. Sales growth without profit
growth is distinct from a margin decline.
Generation receives the supported-function list. A rejected SQL proposal gets one correction with the
validator error; every corrected query passes the same gate before execution. A second rejection fails
explicitly and never executes the rejected statement.
Results identify the actual catalog filenames referenced by the validated query; a bounded catalog
does not establish complete coverage of all uploaded shards.

### Independent SQL gate

The prompt is not the security boundary. `validate_sql()` parses PostgreSQL syntax using SQLGlot and:

- Requires exactly one top-level `SELECT`, including supported CTE-based selects.
- Rejects mutation/DDL, `SELECT INTO`, locks, parameters/placeholders and more than three joins.
- Allows only named safe functions, including common aggregates, rounding, string/date operations
  and selected ranking functions; arbitrary functions such as `pg_sleep` are not permitted.
- Treats SQLGlot's `AND`/`OR` nodes as boolean operators, not callable functions. Their children still
  undergo all function/table checks, including conditions inside `CASE` expressions.
- Allows SQLGlot's typed `LAG` window function for previous-period comparisons; nested expressions
  still undergo function/table checks.
- Resolves physical tables through query scopes, rejecting unapproved tables and catalog/schema-qualified
  references. A query must reference at least one approved physical dataset table.
- Replaces each physical table with a workspace-filtered subquery, preserving the reference alias.
- Adds a bounded top-level `LIMIT`; a smaller nonnegative literal limit is preserved. `OFFSET` is removed.

For example, after the physical table has been approved, the rewrite has this shape:

```sql
-- Before
SELECT SUM(profit) AS total FROM ds_example;
-- After (illustrative workspace UUID)
SELECT SUM(profit) AS total
FROM (
    SELECT * FROM ds_example
    WHERE workspace_id = '00000000-0000-0000-0000-000000000001'
) AS ds_example
LIMIT 100;
```

`ds_example` illustrates the rewrite; real tables are created by
[Processing](../data_processing_agent/README.md) as `ds_<file UUID hex>`. This example is not a migration
or a query to run against an empty database.

### Database execution and results

`Repository.query()` opens a transaction, sets `READ ONLY` and a transaction-local statement timeout,
then executes the rewritten SQL. It fetches at most `SQL_ROW_LIMIT` rows and rejects serialized row results
over 16,000 characters. Defaults are `SQL_ROW_LIMIT=100` (maximum 500) and `SQL_TIMEOUT_MS=5000`.

`SQLResult.sql` is the SQL actually executed, not the original unchecked proposal. The result also contains
column names, rows, row count, a simple execution summary and warnings. Decimal/date-like values are
JSON-safe strings; calculations happen in PostgreSQL, not through float conversion in the model.
The A2A JSON-string envelope preserves large integers instead of converting them to protobuf doubles.
Reaching the row cap adds a warning; it is not proof that additional rows existed.

## 4. A2A contract and failure behavior

The card advertises skill `query`. Studio operation `query` requires `workspace` and a `question` string
of 1-4,000 characters. The shared dispatcher verifies workspace existence before loading the schema.
An authenticated `/.well-known/agent-card.json` and `POST /a2a` expose the service; there is no REST `/query`
endpoint. Use [RemoteSQL](../shared/remote.py) and the [shared A2A transport](../shared/a2a_transport.py).

Invalid model output, `INVALID_SQL`, `UNSAFE_SQL`, missing datasets, database errors and oversized results
fail explicitly. A2A returns a failed task/error artifact; unknown internal exceptions are sanitized.
There is no automatic SQL repair or fake result. Orchestrator may retry worker-level `TimeoutError` once,
but that is not a general retry for database statement errors. It may return a reviewed partial HYBRID
answer if RAG succeeds and SQL fails.

Workspace rewriting and read-only transactions are workshop defenses, **not PostgreSQL RLS** or a complete
multi-tenant security model. The same repository class supports writes for other roles; setting this query
transaction read-only does not imply the database login itself has read-only privileges.

## 5. Configuration, startup and image

Run from the module's **agent-src root**, after [root setup](../README.md), `.env` configuration and migration.
Upload structured data through Chat/Processing before asking dataset questions.

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8084"
python -m uvicorn sql_agent.app:create_app --factory --host 127.0.0.1 --port 8084
```

Configure `DB_*`, the general-model endpoint/deployment, and optional SQL row/timeout limits.
`DB_PROVIDER=horizondb` (default) or `postgresql` selects HorizonDB / Azure PostgreSQL Flexible Server.
Both share one psycopg repository and default to `postgres`; all five Agents must agree.
The shared configuration still requires Embedding model fields although SQL makes no embedding calls;
SQL also does not read Blob originals. See [.env.example](../.env.example) and [config.py](../shared/config.py).
Match `A2A_API_KEY` across services, using at least 24 characters.
Orchestrator's `SQL_URL` must match this advertised peer-reachable URL.

```powershell
az acr build --registry myregistry --image studio-sql:workshop --file sql_agent/Dockerfile --platform linux .
```

This runs an ACR Tasks quick build in the existing ACR named `myregistry` and automatically publishes the image;
replace the name with your workshop ACR resource name, not its login-server hostname. Azure CLI login and
build permissions are required; local Docker is not. Build all five roles using the scripts in the deployment guide.
Build from the root to include shared code. The image runs only SQL as UID 10001 on container port 8080.
For Compose/AKS/ACA and runtime identity, follow the [deployment guide (English/Chinese)](../docs/sandbox-deployment.md).
Host Azure CLI login is not automatically inherited by containers. `/health` does not exercise SQL or the model.

## 6. Tests and current limits

```powershell
python -m pytest -q tests\unit\test_workers.py tests\unit\test_boundaries.py tests\integration\test_a2a.py
```

Run from the same root after installing development dependencies. These tests cover unsafe SQL rejection,
scoped selects/CTEs, exact aggregation, workspace isolation and remote errors using test fixtures.
The opt-in [PostgreSQL test](../tests/integration/test_postgres.py) checks real queries, read-only transactions
and timeout recovery with a disposable database and `STUDIO_TEST_POSTGRES=1`.

There is no SQL authoring UI, arbitrary schema access, automatic query repair or unlimited result export.
The function/table restrictions intentionally limit expressiveness. Current local versus cloud validation
is documented in the [acceptance report](../docs/implementation-report.md).
