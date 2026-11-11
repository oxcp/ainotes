# RAG Agent: retrieve source-bearing evidence

[中文](README_CN.md) | [Module overview](../README.md) | [Orchestrator](../orchestrator_agent/README.md)

## 1. Responsibility and design

This Agent implements the **retrieval part** of RAG, not the complete retrieve-and-generate loop.
It plans source/topic queries, embeds them, searches previously ingested text in PostgreSQL/vector, applies relevance/workspace
checks and returns evidence. The [Orchestrator](../orchestrator_agent/README.md) synthesizes and reviews
the final answer. Semantic retrieval uses the **general model for bounded query planning** and the
**Embedding model for search**; it does not generate the final answer.

The implementation uses the OpenAI SDK adapter plus direct repository queries, not a LangChain
Retriever/vector store wrapper, Microsoft Agent Framework or a local LangGraph.
The [Processing Agent](../data_processing_agent/README.md) must ingest the knowledge first.

## 2. Code reading guide

| File / symbol | What it implements |
|---|---|
| [app.py](app.py): `create_app()` | Selects role `rag` in the shared service factory |
| [agent.py](agent.py): `RagAgent.run()` | Embed, search, validate/filter results and return `RagResult` |
| [shared/retrieval.py](../shared/retrieval.py) | Source grouping, bounded source/topic planning and deduplicated evidence merging |
| [shared/agent_service.py](../shared/agent_service.py) | A2A operation validation, workspace authorization and worker invocation |
| [shared/remote.py](../shared/remote.py): `RemoteRag.run()` | Orchestrator-side A2A client proxy |
| [shared/models.py](../shared/models.py): `Foundry.embed()` | Embeddings API call and vector shape validation |
| [shared/database.py](../shared/database.py): `Repository.search()` | Union of document/review vectors, cosine scores, filters and top-k |
| [shared/contracts.py](../shared/contracts.py): `Evidence`, `RagResult` | Source-bearing result contracts |
| [Dockerfile](Dockerfile) | Independent RAG image entrypoint |

The short worker method is intentional: HTTP/A2A, database and model integration live in shared modules.
`asyncio.to_thread()` keeps the synchronous repository call off the async service loop.

## 3. Retrieval logic

```text
Orchestrator -> RemoteRag.run() -> A2A "retrieve"
  -> validate workspace exists
  -> completed session sources -> source/topic plan (at most 6 searches)
  -> Foundry.embed(semantic queries with English translations)
  -> source-scoped Repository.search(..., filenames=...) (at most 3 concurrent)
  -> threshold / top-k / workspace and source checks
  -> round-robin merge, deduplicate, bound context and report coverage
  <- RagResult with Evidence[]
Orchestrator -> final generation and evidence review
```

1. The dispatcher accepts a query string of 1-4,000 characters and at most eight filter entries.
2. The general model plans at most six source/topic searches from the bounded completed-file inventory.
   Split parts of a source are searched together; originals remain separate. A comparison of two reports
   on three themes can search each report/theme separately. Queries include English translations rather
   than embedding the entire instruction or repeated report titles/footers.
   Embedding model and dimensions must match ingestion; matching dimensions alone is insufficient.
3. `Repository.search()` searches `document_chunks` and `customer_reviews` using `UNION ALL`.
   Both branches scope by workspace and join the corresponding document for source identity. The server
   resolves planned source indices to exact filenames, bound as SQL parameters alongside user filters.
   Requested review rating ranges and sentiment labels are planned as typed `review_filter` constraints,
   applied before vector ranking/`TOP_K`, not embedded as search keywords. High-rating negative and
   low-rating positive reviews use separate searches; missing matches remain an explicit evidence gap.
   For examples constrained only by rating and sentiment, `metadata_only` requires both constraints and
   ranks matching rows by vector similarity without a relevance cutoff. Topic-specific requests keep
   the cutoff; coverage warnings distinguish metadata examples from above-threshold semantic evidence.
4. Similarity is `1 - cosine_distance`, using PostgreSQL/vector's `<=>` operator. The repository applies
   the applicable threshold and exact-match filters, orders descending and caps results at `TOP_K`.
5. `RagAgent.run()` validates each `Evidence`, rechecks the applicable threshold and cap, and raises
   `ISOLATION_FAILURE` if a returned item's workspace or source differs from the requested scope.
6. Results are merged round-robin across searches and deduplicated by record ID. The merged limit is
   `min(12, max(TOP_K, 2 * search_count))`, with a 14,000-character serialized evidence budget.
   No evidence is `insufficient`; a missing search result or truncated merge is `weak`.
   Coverage warnings identify each source/query and retained candidate counts. `sufficient` still does
   not prove topical completeness: the Orchestrator must verify the actual passages and disclose gaps.

The defaults are `RELEVANCE_THRESHOLD=0.4` and `TOP_K=5` **per search**; a comparison can return up to 12
merged records. Upgrade RAG and Orchestrator's shared result contracts together.
This is exact vector search, not an ANN index, reranker or keyword/vector hybrid search.
The separate `review_overview` strategy remains a bounded stored-review scan without model/embedding
calls; it does not establish population counts.

## 4. A2A contract and source information

The card advertises skill `retrieve`. Studio operation `retrieve` requires:

| Argument | Meaning |
|---|---|
| `workspace` | Workspace UUID; checked for existence |
| `question` | Query text; often Orchestrator's planned `rag_goal` |
| `filters` | Optional string-to-string exact-match filters |

Supported filter keys are `filename`, `document_id`, `category`, `product`, `language` and `date`.
Filename/document filters target source fields; the others target stored metadata. There is no range
date filter or automatic metadata inference here. Unknown keys raise `INVALID_FILTER`.
Filter usefulness depends on metadata actually produced during ingestion.

`RagResult` contains `status`, `results`, `top_k`, `retrieval_method`, `truncated` and `warnings`.
Every `Evidence` contains `record_id`, `workspace_id`,
`document_id`, `filename`, `content`, `similarity_score`, optional `page_number`/`section` and `metadata`.
For review evidence, repository metadata includes `source_row_id`. `record_id` is the citation ID that
the Orchestrator may use; RAG does not invent a textual answer or citations when nothing matches.

Authenticated `/.well-known/agent-card.json` and `POST /a2a` use the separate `A2A_API_KEY`.
The shared transport authenticates the peer key and uses official SDK JSON-RPC/SSE.
These operations are not REST `/retrieve` routes; use [RemoteRag](../shared/remote.py) and the
[Studio A2A envelope](../shared/a2a_transport.py).

## 5. Configuration, startup and image

Run from the module's **agent-src root**, after [root setup](../README.md), `.env` configuration and migration.
Prepare documents through Processing; an empty knowledge base cannot yield grounded evidence.

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8083"
python -m uvicorn rag_agent.app:create_app --factory --host 127.0.0.1 --port 8083
```

Configure `DB_*`, Embedding endpoint/deployment/dimensions and optional threshold/top-k settings.
`DB_PROVIDER=horizondb` (default) or `postgresql` selects HorizonDB / Azure PostgreSQL Flexible Server.
Both share one psycopg repository and default to `postgres`; all five Agents must agree.
RAG does not read original Blob files. Configure both general-model and embedding access for semantic
query planning and search. See [.env.example](../.env.example) and
[config.py](../shared/config.py). Keep `A2A_API_KEY` consistent across services;
it must be at least 24 characters. Orchestrator's `RAG_URL` must match
the advertised peer-reachable URL.

```powershell
az acr build --registry myregistry --image studio-rag:workshop --file rag_agent/Dockerfile --platform linux .
```

This runs an ACR Tasks quick build in the existing ACR named `myregistry` and automatically publishes the image;
replace the name with your workshop ACR resource name, not its login-server hostname. Azure CLI login and
build permissions are required; local Docker is not. Build all five roles using the scripts in the deployment guide.
The root build context includes shared code. The image runs only RAG as UID 10001 on container port 8080.
For Compose/AKS/ACA and runtime identity, use the [deployment guide (English/Chinese)](../docs/sandbox-deployment.md);
host Azure CLI login is not automatically inherited by containers. `/health` only checks process liveness.

## 6. Tests and current limits

```powershell
python -m pytest -q tests\unit\test_retrieval.py tests\unit\test_workers.py tests\unit\test_boundaries.py tests\integration\test_a2a.py
```

Run from the same root after installing development dependencies. Tests cover thresholds, filters,
sources, workspace isolation and A2A routing. For real vector queries, use the opt-in
[PostgreSQL test](../tests/integration/test_postgres.py) with `STUDIO_TEST_POSTGRES=1` and a disposable
configured database. Model fixtures do not validate actual cloud embedding quality.

There is no web search, URL fetching, reranking, semantic conflict detection or general-answer fallback.
No evidence is preferable to fabricated evidence. See the [acceptance report](../docs/implementation-report.md)
for local versus actual Azure service validation.
