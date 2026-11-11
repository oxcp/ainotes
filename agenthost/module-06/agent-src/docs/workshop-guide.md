# Workshop guide

> 🌐 语言 / Language: **English** | [中文](workshop-guide_CN.md)

Start with the consolidated [Module 6: Multi-Agent Business Scenarios walkthrough](../../readme.md) for deployment and the
complete upload/query sequence. This page remains a compact instructor reference.

## Objective

Explore multi-agent business scenarios using a simple Product Launch Studio to observe agent routing, shared data, authentication, networking and runtime
lifecycles. The five Agents run independently and collaborate through A2A; LangGraph runs only in the Orchestrator.

## Preparation

Follow the [module README](../../readme.md): local PostgreSQL/vector or selectable HorizonDB / Azure PostgreSQL Flexible Server, configured Foundry general and embedding deployments,
local files or private Azure Blob, migrations, and a shared A2A peer key.
Browser access is keyless: anyone with the Chat URL can access this deployment's data. Verify permissions before class.
Use the actual workshop upload parts in [module-level sample-data](../../sample-data/), not the legacy
`agent-src/sample-data` fixtures. Check source permissions; never upload confidential customer data without authorization.
The [manifest](../../sample-data/manifest.json) records 5 Capgemini PDF parts, 5 Ryder PDF parts,
21 customer-review CSV parts (41,711 source rows) and 1 financial CSV part (700 source rows).
Start with a small subset, then add the remaining parts needed for the question.
Do not upload the manifest or mix [raw originals](../../sample-data/raw/) with their parts in one Session.
Start all five services, not just Chat. Follow [sandbox deployment](sandbox-deployment.md) for per-Agent images,
AKS Sandbox resources or ACA Sandbox setup. Local five-process tests do not establish cloud isolation.
For Linux deployment without a local provisioning SDK, use [the Bash/Bicep/ACA CLI runbook](cli-deployment.md):
reuse Module-01's RG/region/storage account and Module-04's existing SandboxGroup,
create private `data` in that account, provision the selected database, build in ACR,
and deploy five Agents with bounded health checks. Complete the model/Blob/business flows below even
when the deployment script reports all five processes ready.
The root `deploy.sh` runs storage → models → database → config → images → aca and derives the container ARM ID.
The models stage adds an account-level embedding deployment and an APIM operation/backend that validates
the Module-01 UAMI; it does not change existing inference roles or create IAM assignments.
The ACA stage ensures this UAMI is assigned to the group; all five Agents inherit it, with token checks before activation.
`--stage storage` directly retries only incremental management-plane container provisioning;
the account/blob service, networking, versioning and RBAC remain unchanged, and no data is deleted.

`DB_PROVIDER=horizondb` is the default; alternatively set `DB_PROVIDER=postgresql`.
Deploy the selected backend with `deploy-database.sh`; all five Agents must share generic `DB_*` settings.
Both use one psycopg repository and migrations, defaulting to `postgres`, with unchanged business/A2A/model logic.
Region/capacity failures never automatically switch backend. Validate the selected provider against the
actual target deployment; results for one provider do not establish acceptance for the other.

## Demo script

1. Select a **Session** in the automatically loaded dropdown, or create one using **New session**, then click **Connect**. No key is required.
   Session is the UI name for a persistent workspace: reconnecting keeps its data. Queries are scoped to the
   selected Session, but all Sessions are shared and selectable; this is not per-user access isolation.
2. Upload the [first Capgemini PDF part](../../sample-data/01_capgemini_consumer_trends_2025-pages-000001-000020.pdf)
   and [first Ryder PDF part](../../sample-data/02_ryder_ecommerce_consumer_study_2025-pages-000001-000020.pdf):
   see extraction, embedding and storage progress. Add the remaining report parts for wider coverage.
3. Upload the [first review CSV part](../../sample-data/03_customer_reviews-rows-000001-002000.csv):
   see relational rows plus linked embeddings. Full-review statistics require all relevant completed parts;
   aggregate their dataset tables with SQL, not vector counts.
4. Upload the [financial CSV part](../../sample-data/04_financial_sample-rows-000001-000700.csv):
   see relational rows and zero embeddings. Check accepted row counts against the processing report.
5. Ask "Write three taglines for a repairable speaker." Expect DIRECT, no retrieval.
6. Ask "According to the uploaded reports, what matters to consumers?" Expect RAG and source evidence.
7. Ask "Which country generated the highest total profit?" Expect read-only SQL over the uploaded financial
   dataset, grouped by country with summed profit sorted descending. Verify the result against the actual
   CSV; do not use fixed totals from synthetic test fixtures.
8. Ask "Combine consumer trends and sales performance and recommend the best launch market." Expect HYBRID,
   parallel worker progress, exact results and a clearly labeled recommendation.
9. Ask about an absent topic. Expect insufficient evidence rather than invented citations.
10. Restart the service. Sources, datasets and completed run records remain; in-flight runs do not resume.
11. Stop the SQL service and repeat HYBRID. Expect explicit partial/error status, never a fabricated SQL result.
12. Inspect the authenticated Agent Cards and map each peer endpoint to its own sandbox/image.

## Troubleshooting

- `no encryption`: set `DB_SSL_MODE=require` (or verify-full with trust configuration).
- Missing vectors: verify embedding deployment endpoint, authentication scope and dimensions.
- APIM 404: rerun Module-06 `--stage models` to provision `/foundry/openai/v1/embeddings`, then regenerate config.
  Do not bypass the gateway. For 401, check the Agent UAMI `oid` and `ai.azure.com` caller scope;
  backend auth uses APIM's already-authorized system identity.
- SQL rejected: supported function/table allowlists are intentionally narrow.
- No text: use a text PDF rather than a scan.
- Too many chunks: reduce upload size or configure a reasonable limit before class.
- Weak evidence: inspect sources and threshold; never lower the threshold just to force an answer.
- Startup database failure: check network/DNS, TLS, credentials and migrations.
- A2A 401: use the separate matching peer key; never enter it in the browser.
- INVALID_AGENT_CARD: verify public URL, role, expected skills and protocol version; don't disable validation.
- PEER_UNAVAILABLE: check sandbox state, port, networking, DNS and credentials. This sample does not auto-resume sandboxes.
- Docker Desktop unable to start: this affects optional local container execution, not ACR image building.
  Build images remotely with the Bash/PowerShell ACR Tasks scripts in the [deployment guide](sandbox-deployment.md).
- ACR build failure: inspect the Azure CLI run logs, registry permissions, registry build capacity and
  cloud-builder access to dependencies. A previous local `files.pythonhosted.org` TLS failure does not prove
  ACR has the same issue. Do not disable certificate verification or use an untrusted package mirror.
- Compose rejects `ACR_LOGIN_SERVER`: set the existing registry's login-server hostname and the built
  `IMAGE_TAG` in `.env`, authenticate for image pulling, and pull the ACR-built images; do not build locally.

Stop the service and follow the [security cleanup instructions](security.md#cleanup). Review local and Azure costs separately:
agent idle time does not imply the database has scaled to zero.
