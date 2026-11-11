# Data Processing Agent: uploaded files to relational and vector data

[中文](README_CN.md) | [Module overview](../README.md) | [Orchestrator](../orchestrator_agent/README.md)

## 1. Responsibility and design

This worker reads a registered original, extracts its content, infers structured columns, chunks useful
text, generates embeddings and commits the resulting data. It does **not** answer questions, use a
generative LLM to classify files, or run LangGraph. Classification is deterministic:
rows plus chunks produce `HYBRID`, rows alone `STRUCTURED`, otherwise `UNSTRUCTURED`.

The service receives a `FileRef` over A2A, not file bytes or an arbitrary URL. Original files live in Blob;
relational data, vectors and processing reports live in PostgreSQL/vector (one shared psycopg repository for HorizonDB / Azure PostgreSQL Flexible Server).
Embedding calls use the shared OpenAI SDK adapter, not LangChain or Microsoft Agent Framework.

## 2. Code reading guide

| File / symbol | What it implements |
|---|---|
| [app.py](app.py): `create_app()` | Selects role `data-processing` in the shared service factory |
| [agent.py](agent.py): `extract()` | Format-specific parsing and document/table separation |
| [agent.py](agent.py): `normalize_columns()`, `infer()`, `convert()`, `table_data()` | Safe column names, deterministic type inference/conversion and row validation |
| [agent.py](agent.py): `chunk_sections()` | Token-bounded chunks with overlap, Unicode-safe boundaries and source metadata |
| [agent.py](agent.py): `DataProcessingAgent.run()` | Registered-file checks, extraction, embedding, report creation, ingestion and failure marking |
| [shared/storage.py](../shared/storage.py): `BlobStore.read()` | Workspace/URI checks, bounded read, size/checksum verification and format validation |
| [shared/database.py](../shared/database.py): `Repository.ingest()` | Transaction, document lock, dynamic dataset table, vector rows and completed report |
| [shared/models.py](../shared/models.py): `Foundry.embed()` | Batched Embeddings API calls and vector count/dimension validation |
| [Dockerfile](Dockerfile) | Processing-only startup; tokenizer cache populated during build |

## 3. Processing pipeline and data mapping

```text
Orchestrator -> A2A "process" -> workspace authorization
  -> registered FileRef check -> read original -> extract
  -> infer table schema / chunk document and long-text fields
  -> Embedding API, only if chunks exist
  -> one database ingestion transaction
  -> ProcessingResult + A2A completion artifact
```

### Extraction

| File type | Current behavior |
|---|---|
| PDF | Extract page text and preserve page numbers; reject encrypted files; no OCR |
| DOCX | Extract paragraphs/headings and represent tables as text sections |
| TXT / MD | Split paragraphs; retain basic heading context |
| CSV | Decode UTF-8 with optional BOM; first row supplies headers |
| XLSX | Require exactly one populated worksheet; read cached values, not calculate formulas |
| JSON | Nonempty arrays of objects become tables; nested values become JSON strings; other JSON becomes document text |

Table columns are normalized to unique SQL names while retaining `original_name`. Inference handles
boolean, integer, decimal/currency, ISO date/timestamp and text. `numeric()` uses `Decimal`, removes
supported currency/thousands formatting and understands parenthesized negatives.
Blank/malformed rows are skipped; incompatible mixed types remain text instead of being silently coerced.
Limits include 60 columns, `MAX_ROWS` (default 50,000) and 100,000 characters per cell.

### Chunking and embeddings

`chunk_sections()` uses `cl100k_base`, with default `CHUNK_TOKENS=400` and `CHUNK_OVERLAP=60`.
It maps token boundaries back to original text and rechecks token length after slicing, avoiding broken
Unicode characters and oversized re-tokenized chunks. Page/section information is retained.
The `language` metadata is a simple CJK-character heuristic, not a language-detection model.

For table data, long-text columns or names matching review/comment/feedback/description/response/answer/issue
are candidates for embedding. Text shorter than 20 characters and exact duplicate text are skipped;
the original relational rows remain. Vector metadata carries the source row number, field name and
other non-long-text values. The workshop Financial Sample CSV has an explicit filename exception that
disables long-column embeddings. Pure structured input therefore needs no embedding call.

`Foundry.embed()` batches requests (`EMBEDDING_BATCH=32` by default) and checks the vector count and
`EMBEDDING_DIMENSIONS`. `MAX_CHUNKS` defaults to 5,000. The worker emits `extract`, `embedding` and
`storage` progress stages; `embedding` occurs only when there is text to embed.

### Transaction and repeat processing

`run()` requires the incoming `FileRef` to exactly match the registered document metadata. A completed
document immediately returns its saved report. `Repository.ingest()` checks again under a row lock:

- Structured rows go to a generated `ds_<file UUID hex>` table with `workspace_id` and `source_row_id`;
  column descriptions and row counts go to `datasets`.
- Document text vectors go to `document_chunks`; vectors linked to table rows go to `customer_reviews`.
- The document's completed status and `ProcessingResult` are committed in the same transaction.

This protects completed ingestion from duplicate writes, including concurrent callers. It does not
deduplicate concurrent model calls before the transaction. Blob upload and Embedding calls are outside
the database transaction. Exceptions in the processing block mark the file failed and propagate;
there is no success-shaped fallback.

## 4. A2A input/output and boundaries

The card advertises skill `process`; its Studio operation is also `process`. Required `arguments` are
`workspace` and `file` (`FileRef`). The shared dispatcher checks workspace existence before `run()`.
`FileRef` contains `file_id`, `workspace_id`, `filename`, `content_type`, `size_bytes`, `blob_uri` and
`checksum`; it is not permission to fetch any arbitrary URI.

The result is [ProcessingResult](../shared/contracts.py): file identity, classification, storage strategy,
optional table name, loaded rows, embedded records, skipped records, warnings and status.
`skipped_records` combines invalid/empty rows and skipped short/duplicate text; it is not solely a count
of dropped relational rows. The [Orchestrator](../orchestrator_agent/README.md) retains the report and
progress for Chat to poll.

Authenticated discovery uses `/.well-known/agent-card.json`; `POST /a2a` uses official SDK JSON-RPC/SSE
with the Studio envelope in [a2a_transport.py](../shared/a2a_transport.py). There is no REST `/process`
upload endpoint. The separate `A2A_API_KEY` must not be sent to a browser.

## 5. Configuration, startup and image

Run from the module's **agent-src root** after [root setup](../README.md), `.env` configuration and
database migration. For the normal upload flow, start Chat and Orchestrator separately.

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8082"
python -m uvicorn data_processing_agent.app:create_app --factory --host 127.0.0.1 --port 8082
```

Configure `DB_*`, Blob settings and the Embedding endpoint/deployment/dimensions.
`DB_PROVIDER=horizondb` (default) or `postgresql`; the database defaults to `postgres` and all five Agents must agree.
Keep dimensions consistent with migration and RAG. The common factory initializes `Foundry` with general and Embedding
clients, so the common model fields must still be valid even though this worker only calls Embeddings.
See [.env.example](../.env.example) and [config.py](../shared/config.py).
Match `A2A_API_KEY` across services; it must be at least 24 characters.
Orchestrator's `DATA_PROCESSING_URL` must match this advertised URL.

```powershell
az acr build --registry myregistry --image studio-data-processing:workshop --file data_processing_agent/Dockerfile --platform linux .
```

This runs an ACR Tasks quick build in the existing ACR named `myregistry` and automatically publishes the image;
replace the name with your workshop ACR resource name, not its login-server hostname. Azure CLI login and
build permissions are required; local Docker is not. Build all five roles using the scripts in the deployment guide.
Use the root build context, not this package alone. The image starts this role as UID 10001 on container
port 8080. Local originals must be shared with Chat; separate cloud sandboxes use the same private Azure
Blob `data` container and appropriate runtime identity. Host Azure CLI login is not inherited automatically.
See the [deployment guide (English/Chinese)](../docs/sandbox-deployment.md). `/health` is only process liveness.

## 6. Tests and current limits

```powershell
python -m pytest -q tests\unit\test_workers.py tests\unit\test_boundaries.py tests\integration\test_a2a.py
```

With development dependencies installed, these root-level commands cover parsing, type inference,
Unicode/token limits, upload integrity, hybrid/idempotent ingestion and remote processing.
The dedicated [PostgreSQL test](../tests/integration/test_postgres.py) requires a disposable configured
database and explicit `STUDIO_TEST_POSTGRES=1`; model-based tests otherwise use fixtures.

There is no website/README URL crawler, OCR, multi-sheet import, semantic deduplication or automatic Blob
retention. Upload supported files through Chat. Current runtime/cloud evidence is in the
[acceptance report](../docs/implementation-report.md).
