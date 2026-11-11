# Selectable database and five ACA Sandboxes from Bash

> 🌐 语言 / Language: **English** | [中文](cli-deployment_CN.md)

The complete workshop sequence now starts at the [Module 6: Multi-Agent Business Scenarios walkthrough](../../readme.md),
with commands run from the module root. This detailed reference also uses the module root.

This is the **Shell-only provisioning path** for Module-06. It reuses Module-01's existing resource
group, location, ACR and image-pull identity, and Module-04's **existing SandboxGroup**. It does not
recreate either shared group, use local Docker builds, or invoke the Python provisioning SDK.
The [SDK helper](../deploy/aca_sandboxes.py) remains an alternative.

For a complete deployment, the root entry discovers common settings from Module-01 resources automatically;
no manually prepared `.local/aca-common.json` is required. After reviewing the prerequisites, use:

```bash
bash deploy.sh --migrate
```

The entrypoint deploys billable resources directly; review the target and cost first.
After automatic preflight checks, it executes
storage → models → database → config → images → aca and generates/reuses the protected administrator password
and A2A peer key; no workspace key is generated. `--stage storage`,
`--stage images`
or `--stage aca` permits a deliberate retry, not automatic resume. Preserve inventories/config;
the deployment inventory and `aca-config.json` cannot be overwritten. Explicit relative paths are relative to the caller.
The sections below are advanced individual-stage alternatives, not additional steps after a full deployment.

### Required private Blob filesystem view

The root entry resolves Module-01's existing account from the common Blob URL, optional
`STORAGE_ACCOUNT_NAME` / `STORAGE_SUBSCRIPTION_ID` / `STORAGE_RESOURCE_GROUP`, or `stcagenthost<SN>` /
the RG tag. It derives and exports `KB_STORAGE_CONTAINER_ID` automatically; `data` need not already exist.
It reads ARM to verify the account, then incrementally provisions private `data` with `bicep/storage.bicep`, whose account
and blob service are `existing`. It never redeploys them, changes networking/versioning/RBAC or deletes data.
Provisioning uses the management plane even when public networking is disabled.
Missing accounts or mismatched runtime URLs/container IDs stop all later stages. See the
[walkthrough prerequisites](../../readme.md#existing-private-blob-mount-required-for-bash-deployment).
The account must match the common `AZURE_STORAGE_ACCOUNT_URL`. `KB_VOLUME_NAME` defaults to
`studio-kb-data`; `KB_VOLUME_IDENTITY` defaults to the registry identity (`system` or an existing group UAMI).
The selected identity must already be assigned to the group and have container data-read access
(Storage Blob Data Reader or stronger). ARM read access is needed to verify the group/account.
The operator additionally needs container deployment permissions.
Storage networking and RBAC propagation must be ready; the script does not provision them.
This authentication is independent of guest Blob SDK credentials, which remain required.

For individual-stage deployment, create the container and export its ID before standalone `deploy-aca.sh`
(which still requires an explicit ID and does not create containers):

```bash
bash deploy.sh --stage storage
export KB_STORAGE_CONTAINER_ID="$(bash deploy-storage.sh --resolve)"
```

The installed **aca 1.0.0-preview.5** help verifies this native syntax:

```bash
# Group-scoped volume: SystemAssigned, or UserAssigned plus --identity-resource-id <group-uami-id>.
aca sandboxgroup volume create --name studio-kb-data --type AzureBlobByo \
  --storage-container-id "$KB_STORAGE_CONTAINER_ID" --identity-kind SystemAssigned
# Repeat for Chat and Data Processing only, with explicit deployment context:
aca sandbox mount --id "$SANDBOX_ID" --volume studio-kb-data --path /kb-data --readonly
```

These are mechanism examples, not additional commands to run after deployment. Plain `AzureBlob`
allocates platform-owned storage and cannot represent the existing container.
Volume metadata uses `storageContainerResourceId`, `auth.kind="ManagedIdentity"` and
`auth.identity.{kind,resourceId}`, verified against the published
[`azure-containerapps-sandbox` 0.1.0b4 volume models](https://pypi.org/project/azure-containerapps-sandbox/).
The script lists, creates only when absent, then gets and strictly compares this metadata before image imports.
An authentication failure is not absence, and a mismatched existing volume is never silently reused.

ACA deployment automatically verifies local CLI capabilities and required input shape first.
It checks the actual account and identity, mounts Chat and Data Processing only, checks `os.path.ismount`,
drops probe privileges to UID/GID 10001, lists the container and reads the first available file.
Empty containers are valid. No configuration activation marker is written until all mounts and database
checks pass. The manifest also repeats the mount probe before starting the Agent on process restart.
Mounts are runtime attachments, not image contents; group volume/data persist independently of sandboxes.
Blob caching/POSIX semantics apply: this read-only view is not a replacement for the existing Blob SDK.
The optional Python provisioner and AKS renderer do not implement this Bash-only automation.

## What is deployed

| Entrypoint | Responsibility |
|---|---|
| [deploy.sh](../../deploy.sh) | Deploy directly with automatic preflight checks: storage → models → database → config → images → aca; single-stage retry with `--stage` |
| [deploy-storage.sh](../../deploy-storage.sh) + [storage.bicep](../../bicep/storage.bicep) | Incremental ARM provisioning of private `data` only in the reused storage account; account/blob service remain existing |
| [deploy-models.sh](../../deploy-models.sh) + [embedding.bicep](../../bicep/embedding.bicep) | One template deploys the account model and existing-APIM embeddings operation/backend; Azure validates model/quota/policy; existing authorization is unchanged |
| [deploy-database.sh](../../deploy-database.sh) + [database.bicep](../../bicep/database.bicep), [horizondb.bicep](../../bicep/horizondb.bicep) / [postgresql.bicep](../../bicep/postgresql.bicep) | Select HorizonDB or PostgreSQL 17 Flexible Server, configure the vector allowlist and explicit firewall rules; internal functions handle HorizonDB PATCH/admin verification |
| [build-images.sh](../../build-images.sh) | Five direct remote ACR Tasks builds after all inputs/Dockerfiles pass preflight; images must exist before sandbox deployment |
| [deploy-aca.sh](../../deploy-aca.sh) | Five private disk imports, five independent Sandboxes, HTTPS URLs, protected configuration, optional schema migration, bounded health checks and a result table |

All Bash deployment/build scripts run directly and may create billable resources. Mandatory guards remain:
the selected database validates ARM against the selected subscription; ACA validates **local** configuration
and manifests before provisioning. Preflight alone does not prove cloud connectivity.
Only `--migrate` opts into schema migration. Storage `--resolve` and ACA `--capabilities` are read-only operations.
The root image preflight never submits builds; the image stage builds all five images once.
The model script deploys directly with `bash deploy-models.sh` and prints runtime JSON.
The unified `models` stage saves it to `.local/embedding-config.json`; config-only retries require
this file and do not query or redeploy models. The unified `models` stage invokes the model script only once.
Metadata must identify the current APIM/caller and `ai.azure.com` scope. Old direct-endpoint metadata
is rejected; rerun `--stage models` then regenerate config. A failed model/APIM stage invalidates old metadata.

All commands below run from the module root on **Linux Bash**. Paths with spaces are supported.
Set `SUBSCRIPTION_ID` or select the intended Azure CLI subscription; the scripts do not run `az login`
or change the active account. Explicit flags override nonempty environment variables, which override
defaults. `.env` is not automatically sourced. The full environment/default table is in the
[README](../README.md#shell-deployment-defaults).

```bash
az account show -o none 2>/dev/null || az login
az account set --subscription "<subscription-id>"
export RESOURCE_GROUP="rg-agenthost-workshop"  # the RG already deployed in Module-01
umask 077
mkdir -p .local
chmod 700 .local
```

### Prerequisites and boundaries

- Install Azure CLI with Bicep, `aca`, `jq`, `curl`, `openssl` and GNU `timeout`.
  The ACA commands/manifests were checked against **`aca 1.0.0-preview.5`**. This is the independent
  `aca` CLI, not an `az containerapp sandbox` command. Use the
  [official installation instructions](https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-cli);
  review the installer before executing it. No CLI is installed automatically by these scripts.
- The signed-in operator needs HorizonDB deployment permissions and **Container Apps SandboxGroup Data Owner**
  on the existing SandboxGroup. The image-pull UAMI must already have the appropriate ACR pull permissions.
- HorizonDB is a preview service. The subscription must have the provider registered, access, capacity and
  support in the selected region. `LOCATION` (or `--location`) wins; otherwise the script reuses
  **Module-01's actual RG location**, as in Module-04. An unavailable region or missing registration fails
  ARM validation; there is no silent fallback to a different region.
- The HorizonDB template pins `Microsoft.HorizonDb` API **`2026-05-01-preview`**, verified against the
  resource schema. No AVM exists for these resources. Bicep 0.48.1 compiles it without diagnostics;
  older 0.44.1 can compile but warns that its resource-type catalog lacks these preview types.
- `DEPLOYMENT_SN`, or the RG's `deploymentSN` tag when unset, supplies the default names, matching Modules 01/04:
  `acragenthost<SN>`, `id-agenthost-<SN>`, `sandbox-group-agenthost-<SN>`, `hdb-agenthost-<SN>`.
  Override the relevant script arguments for custom resource names. The ACA script explicitly scopes every
  cloud `aca` call to the chosen subscription/RG/group/region; it does not change global ACA configuration.
- **Workshop public access:** HorizonDB uses its public endpoint and defaults to the firewall range
  **`0.0.0.0` - `255.255.255.255`**, in both the Bicep template and Bash wrapper. The pinned preview API uses
  pool firewall rules for this public access; the script does not add unsupported network properties.
  Every IPv4 source can attempt a connection. TLS and strong database authentication remain mandatory.
  This is an intentional workshop-only setting, not a production recommendation.
  For restricted access, supply `DB_FIREWALL_RULES_FILE` / `--firewall-rules-file` with approved
  egress ranges and arrange the matching network path. An existing customer VNet connection can be selected
  through `CUSTOMER_VNET_CONNECTION_NAME` / `--vnet-connection`. No VNet, NAT or private endpoint is created.
- The sandbox manifest explicitly allows outbound traffic for this workshop. Apply an appropriate egress
  policy for production. Published ports are public HTTPS (`--anonymous`); A2A still requires the peer key,
  but anyone with the Chat URL can access its workspaces and data without a browser key.
  This is not a private service-discovery network.
- ACR import authorization alone is not guest authentication. The primary ACA path ensures Module-01's
  UAMI is assigned to the existing SandboxGroup, where all five guests inherit it. `AZURE_CLIENT_ID` selects it
  for `DefaultAzureCredential`; token acquisition is verified in every guest. Service-principal secrets are rejected.
  The `models` stage deploys embeddings in the existing Foundry account and extends Module-01's
  `apim-agenthost-<SN>` (`APIM_NAME` overrides) / `workshop-ai-gateway` with
  `POST /foundry/openai/v1/embeddings`. The operator needs APIM child-resource deployment permissions.
  Parent resources, Responses and existing inference roles are unchanged; no IAM writes are made.
  The operation validates the Agent UAMI `oid` and `https://ai.azure.com` audience **before inherited auth**,
  then overrides the backend/rewrite and authenticates using APIM's existing **system-assigned identity**.
  An attached UAMI is not selected without `client-id`. The account OpenAI endpoint stays behind APIM;
  [official v1 embeddings SDK examples](https://learn.microsoft.com/azure/foundry/openai/how-to/embeddings)
  document `https://ai.azure.com/.default` for this endpoint. Cloud embedding calls never fall back to direct access.
  Use `--stage models` to retry it; no model, account or region fallback is performed.

## 1. Select and provision the database in the existing RG and region

The root entry passes Module-01's UAMI to either provider and enables Entra authentication.
The UAMI is registered as a database Entra administrator for this workshop, not merely an Azure RBAC
principal. Runtime uses `DB_AUTH_MODE=entra` and no `DB_PASSWORD`; the protected administrator password
remains a provisioning input. Guest bootstrap migrates with `--migrate` and verifies actual SQL
read/write privileges with a rolled-back INSERT/UPDATE/SELECT/DELETE transaction before activation.
Use separate migration and least-privilege application identities in production.

`DB_PROVIDER=horizondb` is the default. Set `DB_PROVIDER=postgresql` or pass `--provider postgresql`
to select Azure PostgreSQL Flexible Server. Only these values are accepted; errors never switch backend or region.
Both use one psycopg repository and migrations, preserving Agent/A2A/model behavior. All database settings
use `DB_*`; deployment scripts do not source `.env`. The selected resource provider needs registration,
permissions and capacity in the target region; HorizonDB additionally requires preview access.
The archived [deploy-horizondb.sh](../../notmust/deploy/deploy-horizondb.sh) always selects HorizonDB.
Use the maintained module-root `deploy-database.sh --provider horizondb` entry point for new commands.

Set `DB_PASSWORD` securely in the environment or store the administrator password in a protected file.
There is no default password. Explicit `--password-file` overrides the environment password; otherwise
`DB_PASSWORD_FILE` defaults to module-root `.local/database-password`, outside the image context.
The environment value is copied to a private temporary file and removed from the deployment subprocess's
environment before Azure commands run. Only explicit password-mode deployments put the same password
into runtime configuration; the primary Entra path keeps it provisioning-only.
For example, generate a new workshop password once (do not regenerate it between the two steps):

```bash
openssl rand -base64 36 > .local/database-password
chmod 600 .local/database-password
```

No firewall file is required for the requested workshop public access. The default rule is:

```json
[
  {
    "name": "workshop-public",
    "startIpAddress": "0.0.0.0",
    "endIpAddress": "255.255.255.255"
  }
]
```

The script prints a warning for this all-IPv4 rule. An explicitly supplied JSON file can replace it with
narrower rules or `[]`. Existing pool rules are **not removed** by incremental ARM deployment: changing to
a narrower file does not revoke a previously deployed `workshop-public` rule. Remove that broad rule explicitly
when hardening an existing cluster; merely adding narrow rules or passing `[]` does not close it.

```bash
export DB_PROVIDER="${DB_PROVIDER:-horizondb}"  # Set postgresql for Azure PostgreSQL Flexible Server
database_args=(
  --password-file .local/database-password
  --output .local/database-deployment.json
)
# Review permissions, networking and cost; ARM validation runs automatically before provisioning:
bash deploy-database.sh "${database_args[@]}"
```

The template creates a two-vCore cluster with one replica and `BestEffort` zone placement, plus a parameter
group allowing `vector`. Standalone deployment without `AGENT_IDENTITY_RESOURCE_ID` uses password authentication;
the root UAMI path uses Entra as described above. The password is a Bicep `@secure()` parameter, passed via a mode-0600 temporary parameter file,
never through a literal command argument or output. Temporary files are cleaned on normal exit/error/signals.
Do not run either script with command tracing or Azure/ACA HTTP debug logging.

The PostgreSQL template pins API `2024-08-01`, provisioning PG17 GeneralPurpose Flexible Server:
`DB_SKU_NAME=Standard_D2ds_v5`, `DB_STORAGE_SIZE_GB=32` (auto-growing storage),
`azure.extensions=vector` and `require_secure_transport=on`. Password authentication remains enabled for
the provisioned administrator; when a UAMI is supplied, Entra authentication and its administrator are also
configured, and the primary Agent runtime uses Entra rather than the administrator password.
Override sizing with `--sku-name` / `--storage-size-gb`; `DB_VCORES` applies only to HorizonDB.
Both templates use existing `postgres` and the same explicit public firewall rules.
The manifest is standardized: `status`, `resource_id`, `region` and string `DB_PROVIDER`/connection settings,
never a password. Failures retain resource identity and stage; there is no automatic rollback.
Azure CLI error details are suppressed to prevent credential leakage.

The nonsecret output contains `DB_ENDPOINT`, `DB_PORT`, `DB_DATABASE`,
`DB_USERNAME` and `DB_SSL_MODE`. The initial workshop uses the cluster's existing
**`postgres` database**, not an uncreated `studio` database. `--migrate` in the next step installs the
existing application schema and `CREATE EXTENSION IF NOT EXISTS vector` there. For a separately managed
database, create it/grant permissions beforehand and set its actual name in the runtime config.
Do not point schema initialization at a production/shared application database.

Cluster provisioning is not a database connection test. The ACA script checks database/schema access
from each of the four database-using guests before starting the application.
The administrator account is a workshop convenience; production should separate migration and application
credentials and apply database least privilege.

## 2. Build five images remotely

```bash
bash build-images.sh
```

This runs five `az acr build` quick builds and publishes the images. It does not need a local Docker daemon.
It is a separate, billable build step; the ACA script only imports already-published images.
`ACR_NAME` and `IMAGE_TAG` are read from the environment, falling back to `acragenthost<SN>` and `latest`.
The ACA importer and Compose use the same default tag. To reuse previously built `workshop` images,
export `IMAGE_TAG=workshop` (or explicitly pass `--tag workshop`) to both build and deployment commands.

## 3. Prepare runtime credentials and configuration

For a new full deployment, the `resolve_common` function in `deploy.sh` discovers model, APIM and storage settings and the root
entry writes `.local/aca-common.json`. The default is refreshed during a full deployment and reused on a
config-only retry; do not edit the generated default to express overrides.
For custom settings, prepare a separate `.local/aca-common-custom.json` and export `ACA_COMMON` to its path.
An explicit input must already exist and is not overwritten. The following is its model/Blob portion;
optional runtime settings such as `MAX_ROWS` and `REQUEST_TIMEOUT` can also be supplied as strings.
The config stage merges database/model deployment outputs and UAMI identifiers over common values, then
adds the generated/reused A2A key. Do not supply service-principal secrets or a workspace key.

```json
{
  "BLOB_BACKEND": "azure",
  "AZURE_STORAGE_ACCOUNT_URL": "https://<existing-storage-account>.blob.core.windows.net",
  "AZURE_STORAGE_CONTAINER": "data",
  "AGENT_APIM_ENDPOINT": "https://<existing-apim-host>/foundry",
  "LLM_MODEL": "<deployed-general-model-name>",
  "EMBEDDING_MODEL": "text-embedding-3-small",
  "EMBEDDING_DIMENSIONS": "1536"
}
```

Generated `FOUNDRY_EMBEDDING_BASE_URL` is `<AGENT_APIM_ENDPOINT>/openai/v1`, with
`EMBEDDING_TOKEN_SCOPE=https://ai.azure.com/.default`. Keep `/foundry` in the API base.

The config stage generates/reuses the A2A peer key and assembles the five-role configuration.
**Every environment value must be a string.** The ACA stage overwrites A2A URLs using actual ingress URLs;
no manually predicted Sandbox URL is needed. A config-only run requires the provisioned database manifest
and administrator password file from the database step, even in Entra mode, plus matching saved
`.local/embedding-config.json` from the models stage.

For the custom-input, individual-stage path below, first create the separate JSON using the example above.
This sequence refreshes the model/APIM deployment metadata before generating configuration; omit the models
command only when its saved metadata is already valid for the selected APIM/UAMI. It is not an extra step
after a successful full deployment:

```bash
export ACA_COMMON="$PWD/.local/aca-common-custom.json"
chmod 600 "$ACA_COMMON"
bash deploy.sh --stage models
bash deploy.sh --stage config
```

Keep all these files under ignored `.local`; never put them into the image build context or Git.
The wrapper copies input into its private temporary directory, creates a protected guest directory
**before** upload, uploads a pending JSON file, applies mode `0600`/UID `10001`, and atomically renames it.
Configuration values never appear in `aca sandbox exec` arguments. HTTP authentication uses curl header
**files**, not literal bearer keys on command lines. Preserve original credential files only as required
by your secret-management policy; the scripts remove their own temporary copies, not your inputs.

Each Agent receives only its own role's settings, not the complete five-role JSON.
The final file is `/app/.local/studio-runtime.json`; its `A2A_PUBLIC_URL` is that Agent's own URL.
`shared.sandbox_bootstrap` loads it into the process environment before starting Uvicorn for `Settings` to read.
It is not an Agent Card, is not exposed to the browser, and does not rely on `.env.example` being loaded.

## 4. Deploy and wait for all five Agents

```bash
aca_args=(
  --config "${ACA_CONFIG:-.local/aca-config.json}"
  --output "${ACA_OUTPUT:-.local/aca-deployment.json}"
)
# First deployment into a new workshop database:
bash deploy-aca.sh "${aca_args[@]}" --migrate
```

Run only one deployment command; omit `--migrate` when the schema already exists.
Use `--migrate` only when intentionally applying the application's existing schema. Otherwise the script
requires the schema and `vector` to exist. It does not generate seed data.
The command executed in a guest invokes the image's existing Python application migration and database
driver; **the provisioning host needs no Python or Azure Sandbox SDK**.
This executes only the current `001_initial.sql`, creating a schema without workspace key/owner columns.
`CREATE TABLE IF NOT EXISTS` does not alter legacy tables; a database still containing the old `owner_id`
requires a separate upgrade, not merely rerunning initialization to remove that column.

Sequence:

1. Verify the existing RG/group and resolve ACR/UAMI. Refuse a group in a different region.
2. Import all five images with managed-identity ACR pull, recording disk names/IDs incrementally.
3. Generate schema-validated ACA manifests (JSON is also valid YAML); create five uniquely labeled Sandboxes
   using `aca sandbox apply`, record exact IDs, expose port 8080 and capture HTTPS URLs.
4. Deliver each role's configuration with all five addresses. A bounded startup gate prevents application
   launch before all configurations and database checks finish.
5. Optionally migrate once in the Orchestrator guest, then check `workspaces` and the `vector` type from all four database guests.
6. Release the startup gates. The existing bootstrap drops to UID 10001 and `exec`s that role's Uvicorn process;
   no terminal-bound background process is used.
7. Poll all five `/health` endpoints and authenticated Agent Cards within a **shared deadline**. Verify role,
   streaming support, JSON-RPC version and the exact advertised A2A URL.
8. Perform a read-only `GET /api/workspaces` through Chat -> A2A -> Orchestrator -> database.
   The Chat browser API is keyless; the internal A2A hop still uses peer authentication.
9. Print one row per Agent with status/URL and retain a nonsecret deployment inventory. Any failure exits
   nonzero; health timeouts are not reported as success.

Example success output (URLs are illustrative):

```text
AGENT             STATUS       URL
chat              ready        https://<chat-ingress>
orchestrator      ready        https://<orchestrator-ingress>
data-processing   ready        https://<processing-ingress>
rag               ready        https://<rag-ingress>
sql               ready        https://<sql-ingress>
Inventory: .../.local/aca-deployment.json
```

Open the Chat URL, select a **Session** or create one with **New session**, then click **Connect**; no browser key is needed.
Session is the UI name for the existing persistent workspace; data and API identifiers are unchanged.
Workspace visibility is independent of deployment keys. Never expose the A2A key in the browser.
Ready means process/card/database checks and the read-only Chat A2A smoke check passed; it does **not**
prove Foundry generation/embeddings, Blob upload or all four business routes. Complete the
[workshop acceptance flows](workshop-guide.md) separately.

Each ACA operation is bounded by `--operation-timeout` (default 900 seconds); the guest activation gate is
bounded by 3600 seconds. A slow/failed setup should be investigated and cleaned up rather than left waiting.
Idle auto-suspend defaults to `AUTO_SUSPEND_MINS=0` (disabled), unlike Module-04's disposable workloads.
Use positive `--auto-suspend-mins` values only to opt in: this application does not wake suspended workers,
and Manual-activation ports return an unavailable response instead of resuming on HTTP/A2A traffic.
Keeping Agents running incurs idle compute charges; suspend them deliberately when unused and resume
before use. Do not let active workflows cross an idle-suspend boundary.
Existing sandboxes need an explicit lifecycle update; script defaults affect new deployments only.
CPU/memory default to `SANDBOX_CPU=1000m` / `SANDBOX_MEMORY=2048Mi`.

## Failure, retry and cleanup

- `failed_stage=volume`: inspect account URL, group identity, data role, storage network access and CLI BYO
  support. A different container/identity under the same name requires a new `KB_VOLUME_NAME`, not deleting
  the shared volume. Volume creation and listing failures stop before any image import.
- `failed_stage=mount`: `failed_role` identifies the guest. Inspect the native mount and UID 10001 access,
  never substitute a directory or change stored-data permissions to bypass the gate. All activation and
  readiness is blocked. Inventory retains volume details and successful per-role mount checks.

- Existing output files are refused to preserve earlier inventories. Use a new `--output` after inspecting
  the previous attempt. **ACA re-apply creates new disk images and Sandboxes**, not an in-place update.
- Failures retain known IDs, names, unique deployment labels and stage/status. If a cloud operation
  completed but its response was lost, find that resource by its recorded disk name/deployment label
  before retrying. Do not assume a missing returned ID means no resource was created.
- Neither script deletes failed resources, removes database data, rotates credentials or changes shared
  storage networking/RBAC. The models stage leaves Module-01's Foundry authorization unchanged, and the ACA stage may add
  the Module-01 UAMI to the group. HorizonDB incremental deployment also does not remove previously created firewall rules.
- Inspect only the five resources in the specific inventory. Delete those Sandboxes first, then their
  disk images. **Never delete the shared Module-04 SandboxGroup or Module-01 resource group.**
- For a timed-out Agent, use the exact recorded ID with `aca sandbox get` / `aca sandbox exec` in the
  recorded subscription/RG/group/region. Inspect guest diagnostics securely; configuration and errors can
  contain credentials. Do not dump runtime config into a support log.
- A database check failure usually means DNS/egress/firewall/TLS/auth, an extension allowlist not yet applied,
  or a missing schema. A healthy `/health` response alone would not have detected these issues.

## Validation evidence and official references

The shell regression suite stubs Azure operations and HTTP responses, checks failures/timeouts and secret
handling, and can call the actual ACA CLI for **offline manifest validation**:

```bash
REAL_ACA="$(command -v aca)" bash agent-src/tests/deploy-shell.test.sh
```

Bicep compilation and offline tests are not Azure deployment acceptance. Keep deployment inventories and
business acceptance results for the actual database, built images and five sandboxes separately;
historical or offline results do not prove the current deployment works.

- [HorizonDB cluster schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.horizondb/2026-05-01-preview/clusters)
- [Allow HorizonDB extensions](https://learn.microsoft.com/en-us/azure/horizondb/extensions/how-to-allow-extensions)
- [HorizonDB pgvector](https://learn.microsoft.com/en-us/azure/horizondb/ai/vector-search-pgvector)
- [PostgreSQL Flexible Server resource schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.dbforpostgresql/2024-08-01/flexibleservers)
- [PostgreSQL extension allowlist](https://learn.microsoft.com/en-us/azure/postgresql/extensions/how-to-allow-extensions)
- [PostgreSQL TLS](https://learn.microsoft.com/en-us/azure/postgresql/security/security-tls)
- [ACA Sandboxes](https://sandboxes.azure.com/docs/sandboxes/sandboxes)
- [Native volumes and BYO containers](https://sandboxes.azure.com/docs/sandboxes/volumes)
- [Disk images](https://sandboxes.azure.com/docs/sandboxes/disk-images)
- [Files](https://sandboxes.azure.com/docs/sandboxes/sandbox/files)
- [Ports](https://sandboxes.azure.com/docs/sandboxes/sandbox/ports)
