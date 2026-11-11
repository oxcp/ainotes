# Security and operations

> 🌐 语言 / Language: **English** | [中文](security_CN.md)

- Chat's browser APIs are intentionally keyless for individually provisioned workshops. Anyone who can reach
  the Chat URL can list/create workspaces, upload, and query this deployment's data. Do not upload sensitive data.
  Workspaces have no key-derived owner; rotating peer credentials does not hide existing data.
  For shared production use, add verified Entra JWT identity and per-user ownership.
- Use HTTPS externally. Bind the documented local server to loopback. Same-origin UI only; no permissive CORS.
- A2A uses a distinct peer bearer key for both discovery and collaboration. The browser never receives this key.
  Cards cannot redirect the configured endpoint or change the expected role/capability. Workers reject nonexistent
  workspaces and scope file/query operations to the selected workspace. This shared-key workshop trust model
  is not production per-Agent/per-user identity: add scoped credentials or verified workload JWTs before multi-tenancy.
- Use TLS/mTLS between sandboxes outside trusted local networks. The AKS sample's internal HTTP and shared UAMI
  are workshop simplifications; NetworkPolicies restrict inbound worker traffic but do not encrypt it.
- ACA anonymous Chat ingress has no browser access gate; A2A endpoints still require the peer bearer key.
  Do not equate an image-pull managed
  identity with an available guest runtime identity. Configure and verify guest credentials separately.
- Original uploads stay in private storage, but their contents can be queried through the public workshop API.
  Azure SDK uses DefaultAzureCredential and Storage Blob Data Contributor.
  No account keys, public containers or SAS URLs are required.
- Selected database credentials come from generic `DB_*` environment variables; `DB_PROVIDER` is `horizondb` (default) or `postgresql`.
  The primary Bash cloud path uses `DB_AUTH_MODE=entra` with the Module-01 UAMI and no runtime `DB_PASSWORD`.
  The administrator password remains a protected provisioning input. Local/explicit password-mode deployments
  still require a matching database password; they are not the primary cloud authentication path.
  Azure TLS is required. Prefer `verify-full` with a configured trust
  store. Use private network/DNS connectivity where required.
- SQL AST permits one SELECT (including SELECT CTEs), approved dataset tables and a small safe function allowlist.
  Physical tables are wrapped in workspace predicates. Mutating CTEs, catalogs, INTO, locks, multiple statements,
  unapproved functions and excess joins are rejected. Database transactions are read-only with statement timeout.
- Workshop uses one database role for ingestion and queries. Read-only transactions protect the query path;
  deploy separate least-privileged roles and database-level RLS for production defense in depth.
- Treat all uploaded content as untrusted prompt data. It cannot set workspace IDs or choose arbitrary database
  tables. Model output uses Pydantic schemas and citation IDs are checked independently of the model reviewer.
  Prompt injection cannot be guaranteed eliminated by prompting alone.
- Rendering constructs text nodes (no user-controlled innerHTML). Basic Markdown headings, paragraphs and code
  fences are supported; raw HTML and automatic external links are intentionally disabled. CSP blocks external scripts.
- Uploads have filename, MIME, size, archive-entry and expansion limits. Archives are read, never extracted onto
  disk. PDF parsing remains a resource-sensitive operation: run untrusted production parsing in isolated workers.
- Logs emit IDs, stages, counters, timings and error categories, not raw prompts, SQL data, credentials or exception
  messages. Evidence is persisted in the authorized database, not dumped to logs.
- Workspace records, vectors, run evidence and sessionStorage chat history may contain sensitive data.
  Define retention with the customer. No automatic retention deletion or user-facing delete API is implemented.

## Cleanup

For a disposable local database, `docker compose down -v` deletes this Compose project's database volume.
Delete only this module's `.local/data` contents after stopping the application; do not delete a shared Blob container.
For Azure, an administrator must remove only the selected workspace's dynamic dataset tables, review/chunk
records, dataset metadata, runs and insights, then document records, and finally the workspace.
Afterward delete only Blob objects under its UUID prefix.
Do not accept a model-generated cleanup query. Check Blob soft-delete/version retention and database backups:
logical deletion is not immediate physical erasure.
