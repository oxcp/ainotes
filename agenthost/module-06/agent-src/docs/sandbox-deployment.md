# Independent Agent images and sandboxes

> 🌐 语言 / Language: **English** | [中文](sandbox-deployment_CN.md)

The five production services communicate using A2A 1.0 JSON-RPC/SSE (official `a2a-sdk==1.3.0`).
LangGraph remains inside the Orchestrator. Neither Chat nor the Orchestrator constructs local worker Agents.
All five publish authenticated `/.well-known/agent-card.json` and handle `POST /a2a`.
No service registry is required: configure trusted peer base URLs; clients discover and verify cards before
using their declared protocol endpoints. Do not copy URLs from untrusted documents.

## Script responsibilities and deployment targets

The [deploy directory](../deploy) supports **five independent Agents on either AKS Sandbox or ACA Sandbox**.
Choose one target for a workshop deployment. Building images, generating manifests and provisioning sandboxes
are separate steps; no script provisions the complete surrounding Azure infrastructure.

For the new Linux **Bash + Bicep + ACA CLI** path, follow
[the CLI deployment runbook](cli-deployment.md). It provisions the selected database in Module-01's existing RG/region
and reuses Module-04's existing SandboxGroup; the SDK remains an alternative, not a prerequisite.

The primary Bash root entry first creates/reuses private `data` in Module-01's existing storage account
through incremental management-plane Bicep; it never redeploys the account/blob service, changes
networking/versioning/RBAC or deletes data. Retry with `bash deploy.sh --stage storage`.
It derives the container ARM ID automatically; standalone `deploy-aca.sh` still requires an explicit ID.
Only the primary Bash path automatically attaches this private `data` container to the Chat and Data Processing
sandboxes at `/kb-data` (read-only), through one group-scoped `AzureBlobByo` volume. Orchestrator, RAG and SQL do not mount it. See the
[mount prerequisites and failure handling](../../readme.md#existing-private-blob-mount-required-for-bash-deployment).
The CLI validates every mount as UID 10001 before any activation; the Python SDK helper and AKS renderer
below do not implement this mount automation. Blob SDK storage/business behavior remains unchanged.

| Tool | Responsibility | Target / side effects |
|---|---|---|
| [build-images.ps1](../deploy/build-images.ps1) | PowerShell: submit five remote `az acr build` runs to an existing ACR | Builds and publishes images via ACR Tasks; no local Docker or sandbox deployment |
| [deploy.sh](../../deploy.sh) | Direct Bash deployment with automatic preflight checks and stage selection | Deploys billable resources directly; module-root artifacts in `.local` |
| [deploy-storage.sh](../../deploy-storage.sh), [storage.bicep](../../bicep/storage.bicep) | Create private `data` directly; `--resolve` only reads ARM to resolve the account/container ID | Reused Module-01 account; no Blob data-plane provisioning |
| [build-images.sh](../../build-images.sh) | Bash equivalent of the ACR Tasks quick builds | Same images and `agent-src` build context; publishes directly after preflight; set `IMAGE_TAG` consistently |
| [deploy-database.sh](../../deploy-database.sh) | Automatically validate then provision unified [database.bicep](../../bicep/database.bicep), vector allowlist and explicit firewall rules | Existing Module-01 RG and region; no new RG |
| [deploy-aca.sh](../../deploy-aca.sh) | Bash + `aca`: five imports/Sandboxes, URLs/configuration, optional schema migration, bounded health/card/DB/A2A checks | Existing Module-04 SandboxGroup; no local provisioning SDK; directly creates billable resources after validation |
| [render_sandboxes.py](../deploy/render_sandboxes.py) `--target aks` | Generate Namespace, ServiceAccounts, five Sandbox CRDs, Services and NetworkPolicies | Writes JSON only; apply separately with `kubectl` to an existing prepared AKS cluster |
| [render_sandboxes.py](../deploy/render_sandboxes.py) `--target aca` | Generate five-image/command/port launch inventory | Writes JSON only; not an ARM template and does not create sandboxes |
| [aca_sandboxes.py](../deploy/aca_sandboxes.py) | Validate configuration; with `--apply`, import disk images, create five sandboxes, wire URLs/configuration and probe them | Actual ACA deployment into an existing SandboxGroup; `--apply` creates billable resources |

`DB_PROVIDER=horizondb` is the default; alternatively set `DB_PROVIDER=postgresql` / `--provider postgresql`.
All five Agents share generic `DB_*` settings, one psycopg repository and identical migrations, defaulting to `postgres`.
Both PG17 templates produce the same password-free resource/connection manifest; ACA assembly extracts only `DB_*`.
The AKS renderer reads those same variables from each Agent's protected configuration Secret.
Database provisioning/region/capacity failures never switch provider or modify Module-01 resources.

PowerShell and Bash are alternative image-build entrypoints. Choose either the Bash/ACA CLI deployment
or the Python SDK deployment; do not run both for the same intended five instances.
`__init__.py` makes `deploy` a Python package; it is not a deployment command.
Python examples below assume the module virtual environment is activated (`python` must be Python 3.11+).

## Images

The workshop reference is [Module-03's build step](../../../module-03/prepare-agent-sandbox.sh):
`az acr build` runs a quick build through ACR Tasks in the existing Module-01 registry.
[Module-04](../../../module-04/sandbox-deploy.sh) reuses that published image; it does not define a named
persistent Task. Module-06 follows the same quick-build pattern for its five images.
This is not `az acr task run --name ...`; no persistent Task is created, modified or assumed.

Run from `agent-src` with Azure CLI installed, logged in and targeting the intended subscription.
The existing ACR must permit ACR Tasks and the caller must be authorized to build/publish images.
No local Docker CLI/daemon or `az acr login` is required for cloud builds.

```powershell
az login
az account set --subscription "<subscription-id>"
.\deploy\build-images.ps1 -Registry myregistry -Tag workshop
```

Linux Bash equivalent:

```bash
az login
az account set --subscription "<subscription-id>"
bash ../build-images.sh --registry myregistry --tag workshop
```

The script resolves the build context relative to its own location, so it can also be called by absolute path
from another working directory. Paths with spaces are supported. `--registry` / `-Registry` is the ACR
**resource name** (for example `acragenthost<deploymentSN>`), not a URL or `myregistry.azurecr.io`.
`--tag` defaults to `IMAGE_TAG` or `latest`, matching Module-04; the explicit `workshop` examples above
remain valid when intentionally choosing that tag. Bash also accepts `ACR_NAME`, or discovers the existing
registry from `DEPLOYMENT_SN` / the Module-01 RG tag. `--help` shows Bash usage. Each call waits for completion and automatically
publishes the resulting image. `--push` / `-Push` were removed; cloud builds always publish.
Submitting builds uploads local source to the selected ACR and can incur charges.
Use only your approved registry, review the build context, and never include runtime secrets.
The scripts stop on the first failed build, leaving already published images intact. They do not log in,
create a registry, retry failed builds, run migrations or deploy containers.
Invoking it with `bash` does not require setting its executable bit.

For example, the Chat step runs `az acr build --registry myregistry --image studio-chat:workshop
--file chat_agent/Dockerfile --platform linux <agent-src-root>`. Each role uses its own Dockerfile.
The login server used by Compose and the Python deployment tools is a different value:

```bash
az acr show --name myregistry --query loginServer --output tsv
```

Use that returned hostname for `ACR_LOGIN_SERVER` and for Python deployment `--registry` arguments below.
Do not pass the bare ACR resource name to the manifest renderer or ACA image importer.

| Role | Dockerfile / entrypoint | Image |
|---|---|---|
| Chat | `chat_agent/Dockerfile`, `chat_agent.app:create_app` | `studio-chat` |
| Orchestrator | `orchestrator_agent/Dockerfile`, `orchestrator_agent.app:create_app` | `studio-orchestrator` |
| Processing | `data_processing_agent/Dockerfile`, `data_processing_agent.app:create_app` | `studio-data-processing` |
| RAG | `rag_agent/Dockerfile`, `rag_agent.app:create_app` | `studio-rag` |
| SQL | `sql_agent/Dockerfile`, `sql_agent.app:create_app` | `studio-sql` |

Build context is this module's `agent-src` directory, not an individual package. Shared Python libraries are
packaged together, but each image starts only its designated Agent. Images run as UID 10001, listen on 8080,
and include the tokenizer cache. The duplicate root Chat Dockerfile was archived under
[notmust](../../notmust/agent-src/Dockerfile); use `chat_agent/Dockerfile` with the `agent-src` build context.
The [.dockerignore](../.dockerignore) excludes `.env`, `.env.*` (except `.env.example`), `.local`, the venv
and test/build artifacts from the uploaded context. Do not put secret files elsewhere in the source tree.
Never bake credentials into an image. `/health` confirms process responsiveness, not data/model connectivity.

## Local five-service development

Build/publish in ACR first, then set up `.env`. Set `ACR_LOGIN_SERVER` to the hostname returned by
`az acr show` and `IMAGE_TAG` to the built tag (default `latest`). The peer key must be shared by all
five services; no browser/workspace key is required.
Docker is needed here only to run/pull containers, not to build images.
The Compose services have no local `build` definitions.

```sh
az acr login --name myregistry
docker compose -f compose.yaml -f compose.agents.yaml pull
docker compose -f compose.yaml -f compose.agents.yaml up -d db
docker compose -f compose.yaml -f compose.agents.yaml run --rm sql python -m shared.database
docker compose -f compose.yaml -f compose.agents.yaml up -d --no-build
docker compose -f compose.yaml -f compose.agents.yaml ps
```

Only Chat is published on `127.0.0.1:8080`; other services are discovered over the Compose network.
Local originals use a shared development volume mounted into Chat and Processing. This is **not** the cloud
storage design. DefaultAzureCredential still needs a working identity inside each container: a host `az login`
does not automatically authenticate a container. Provide a development service-principal credential through
environment/secrets, or run local Python processes with Azure CLI identity. Do not mount your entire home directory.
Keep container credential setup separate from production AKS workload identity.

For five native terminals, activate the same virtual environment, then set the public URL and start the matching
entrypoint. Peer URLs in `.env.example` already match ports 8081-8084:

```powershell
# Example Orchestrator terminal; repeat for chat:8080, data_processing:8082, rag:8083, sql:8084.
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8081"
python -m uvicorn orchestrator_agent.app:create_app --factory --host 127.0.0.1 --port 8081
```

Linux Bash equivalent, again from `agent-src`:

```bash
A2A_PUBLIC_URL=http://127.0.0.1:8081 \
  python -m uvicorn orchestrator_agent.app:create_app --factory --host 127.0.0.1 --port 8081
```

## AKS Sandbox (Module-03 pattern)

Prerequisites: an AKS cluster with the agent-sandbox controller and `agents.x-k8s.io/v1beta1` Sandbox CRD,
an Azure Linux Kata node pool with `kata-vm-isolation`, the Module-03 labels/taint convention, workload identity
and OIDC enabled, registry pull authorization, and network access to Blob, HorizonDB and model endpoints.
This module does **not** modify or install Module-03 resources.

```powershell
python deploy\render_sandboxes.py --target aks --registry myregistry.azurecr.io --tag workshop `
  --namespace studio --identity-client-id <uami-client-id> --output .local\aks-sandboxes.json
kubectl create namespace studio
```

Linux Bash equivalent:

```bash
python -m deploy.render_sandboxes --target aks --registry myregistry.azurecr.io --tag workshop \
  --namespace studio --identity-client-id "<uami-client-id>" --output .local/aks-sandboxes.json
kubectl create namespace studio
```

Replace quoted placeholders with your existing resources' identifiers before running cloud commands.
The renderer does not create the cluster, install the Sandbox controller or configure workload identity.

Create one Kubernetes Secret named `studio-<role>-config` for each role from a protected environment file.
Use role names `chat`, `orchestrator`, `data-processing`, `rag`, `sql`.
Each must contain the keys from `.env.example`, with real cloud endpoints, TLS and credentials; the renderer
overrides `BLOB_BACKEND=azure` and all A2A endpoint variables. Keep the peer key server-side.
The current shared settings schema requires DB/model values even for Chat, but Chat never constructs DB/model clients.
Production least-privilege separation of configuration should be added before multi-tenant use.

```powershell
# Example; keep the source file outside version control.
kubectl -n studio create secret generic studio-chat-config --from-env-file=.local\chat.env
```

Linux Bash, after preparing all five protected environment files outside version control:

```bash
(
  set -e
  for role in chat orchestrator data-processing rag sql; do
    kubectl -n studio create secret generic "studio-${role}-config" \
      --from-env-file=".local/${role}.env"
  done
)
```

Federate the specified UAMI with each of the five service-account subjects:
`system:serviceaccount:studio:studio-<role>`, using the cluster OIDC issuer and audience
`api://AzureADTokenExchange`. Grant model and storage data-plane roles as required; give the cluster's
image-pull identity registry access. A single shared UAMI is the workshop baseline, not a production trust boundary.

```powershell
kubectl apply --dry-run=server -f .local\aks-sandboxes.json
kubectl apply -f .local\aks-sandboxes.json
kubectl -n studio get sandboxes,pods,services
kubectl -n studio port-forward service/studio-chat-api 8080:8080
```

Linux Bash equivalent (only apply after the server-side dry run succeeds):

```bash
(
  set -e
  kubectl apply --dry-run=server -f .local/aks-sandboxes.json
  kubectl apply -f .local/aks-sandboxes.json
  kubectl -n studio get sandboxes,pods,services
  kubectl -n studio port-forward service/studio-chat-api 8080:8080
)
```

Five Sandbox objects run independent Kata pods. Explicit `-api` ClusterIP Services avoid colliding with
controller-created services. Namespace-scoped NetworkPolicies allow Chat → Orchestrator → workers only;
Chat ingress is denied except administrative port-forward. For external Chat ingress, add a TLS ingress/gateway
and its explicit NetworkPolicy rule. No public LoadBalancer is created. Egress is not restricted by this sample;
configure approved DNS, model, Blob and database destinations for production.
HTTP inside the cluster is a workshop simplification: use mTLS/service-mesh or TLS endpoints if the network is not
trusted. A2A bearer keys do not encrypt traffic. A suspended worker returns an explicit unavailable/timeout result;
no automatic wake gateway is implemented.

## ACA Sandboxes (Module-04 runtime model)

This means **Microsoft.App/SandboxGroups and individual sandbox micro-VMs**, not ordinary Container Apps
and not Dynamic Sessions. Use the supported [ACA Sandboxes portal](https://sandboxes.azure.com/).
Module-04's older script contains placeholder lifecycle commands; this module does not copy those commands.

Generate a launch inventory (NOT an ARM deployment template):

```powershell
python deploy\render_sandboxes.py --target aca --registry myregistry.azurecr.io --tag workshop `
  --output .local\aca-launch.json
```

Linux Bash equivalent:

```bash
python -m deploy.render_sandboxes --target aca --registry myregistry.azurecr.io --tag workshop \
  --output .local/aca-launch.json
```

### Explicit SDK deployment

The Shell-only alternative is documented in [CLI deployment](cli-deployment.md), including exact prerequisites,
HorizonDB provisioning, protected config assembly, startup checks, result output and failure handling.

The preview SDK is available as `azure-containerapps-sandbox==0.1.0b4` (requires checking prereleases).
The deployment helper uses its verified disk-image, sandbox, port and file-transfer APIs. It targets an
**existing** SandboxGroup and never creates/deletes the surrounding resource group.

Prepare `.local/aca-config.json` as an object with exactly five keys: `chat`, `orchestrator`, `data-processing`,
`rag`, `sql`. Each value is a string-to-string map of environment variables from `.env.example`, populated for
Azure. All roles use the same A2A peer key and external data-source configuration; there is no workspace key.
Use `BLOB_BACKEND=azure` and
database TLS; provide runtime identity variables appropriate for your approved guest authentication mechanism.
Keep this secret file out of source control. The helper replaces A2A URL variables after port allocation.
Prepare the database schema, permissions and guest identity separately before activation: this optional
helper does not perform the Bash path's schema bootstrap, four-guest database checks or native Blob mounts.

```powershell
python -m pip install -e ".[sandbox]"
python -m deploy.aca_sandboxes --subscription <subscription-id> --resource-group <existing-rg> `
  --sandbox-group <existing-group> --region <region> --registry myregistry.azurecr.io --tag workshop `
  --registry-identity <image-pull-uami-resource-id> --config .local\aca-config.json
# The command above only validates configuration. Add --apply to create billable resources.
```

With `--apply`, the helper imports five disk images, launches five sandboxes, publishes HTTPS ports,
uploads mode-0600 configuration and atomically activates each guest. A2A endpoints require application-level
peer authentication; browser APIs remain keyless.
It verifies process health and authenticated cards. It records created disk/sandbox IDs and URLs after every
step in `.local/aca-deployment.json`; failures are explicit and retain this cleanup inventory without credentials.
No automatic destructive rollback is performed.

The image entrypoint is overridden to `python -m shared.sandbox_bootstrap <role>`. This waits up to 600 seconds
for protected configuration, drops to UID 10001 and execs the Agent. It avoids dependence on an interactive shell
or background `nohup` process. Configuration is delivered by the authenticated SDK as a pending file, then
ownership is set and the file is renamed; the command contains no secrets.
Anonymous platform ports expose public HTTPS routes. A2A authentication remains mandatory, but browser APIs
are keyless: anyone with the Chat URL can access this deployment's workspaces and data.
Unit tests check the installed SDK's real signatures; they do not establish cloud acceptance for this optional path.

### Linux Bash SDK deployment

Use the same protected `.local/aca-config.json`, existing SandboxGroup and runtime identity prerequisites
described above. The Bash build script must have pushed the five images before importing them from the registry.
With the module virtual environment activated, run from `agent-src`:

```bash
python -m pip install -e ".[sandbox]"
aca_args=(
  --subscription "<subscription-id>"
  --resource-group "<existing-rg>"
  --sandbox-group "<existing-group>"
  --region "<region>"
  --registry myregistry.azurecr.io
  --tag workshop
  --registry-identity "<image-pull-uami-resource-id>"
  --config .local/aca-config.json
  --output .local/aca-deployment.json
)
python -m deploy.aca_sandboxes "${aca_args[@]}"
```

The command above validates local configuration only; it does not check Azure permissions or deploy resources.
After reviewing configuration, costs and the intended target, explicitly deploy in the **same Bash session**:

```bash
python -m deploy.aca_sandboxes "${aca_args[@]}" --apply
```

Do not treat re-running `--apply` as an idempotent update: the helper generates a new deployment ID and creates
new disk images/sandboxes. Preserve each deployment inventory for cleanup; reusing the default output path
overwrites the prior inventory. It neither creates a SandboxGroup nor deletes resources automatically.

### Alternative portal deployment

1. Select the intended subscription/resource group/region and create or reuse a **Sandbox Group**.
   The operator needs **Container Apps SandboxGroup Data Owner**. Check preview availability and quota.
2. In **Disk images**, import each of the five registry images. For private ACR, configure supported registry
   authentication (managed identity is preferred). These are root filesystems: do not assume Docker CMD is
   automatically run by the sandbox boot process.
3. Create **five** sandboxes, one from each imported disk image, labeled with its role. Set CPU/memory and
   disable auto-suspend for these persistent services. Manual-activation ports do not wake suspended
   workers. This incurs idle compute charges; suspend deliberately when unused, never during active requests.
4. Configure private data/model reachability. Set `BLOB_BACKEND=azure`, the same private `data` container and
   selected HorizonDB/PostgreSQL Flexible Server database in all services. Do not use the local-files adapter across ACA sandboxes.
5. Add port 8080 to each sandbox and record its generated HTTPS URL. The portal's **Anonymous** ingress mode
   means no platform ingress authentication. Application authentication protects A2A endpoints and cards,
   not the browser APIs: anyone with the Chat URL can access the shared workspaces and data.
   Do not expose a worker with authentication removed. Use additional network restrictions where
   available. The process health route deliberately returns no secrets.
6. Prepare one protected `.env` per role: `A2A_PUBLIC_URL` equals that sandbox's HTTPS base URL;
   `ORCHESTRATOR_URL`, `DATA_PROCESSING_URL`, `RAG_URL`, `SQL_URL` equal the matching other sandbox URLs.
   Include the shared peer key and DB TLS settings. Assign Module-01's UAMI to the existing group;
   all five sandboxes inherit it, and `AZURE_CLIENT_ID` selects it for Foundry/Blob/database tokens.
   Verify tokens and data access inside the guest; the primary Bash path performs these checks and rejects service-principal secrets.
7. Transfer each environment file to `/app/.env` using the supported CLI/SDK file-write feature, protect it with
   owner-only permissions for UID 10001, and remove temporary local copies according to your credential policy.
   Do not paste secrets into shell command lines, logs, Agent Cards or the launch inventory.
   This is the manual portal alternative; the primary Bash path instead delivers protected runtime JSON
   and loads it through `shared.sandbox_bootstrap`. Prepare/verify the database schema and identity permissions
   separately before starting Agents manually.
8. Start the command listed in the inventory from `/app`, as UID 10001. Example for the RAG guest shell:

   ```sh
   cd /app
   python -m uvicorn rag_agent.app:create_app --factory --host 0.0.0.0 --port 8080
   ```

   Use the platform's supported persistent process/session facility so the process outlives the interactive
   shell. Explicitly verify responsiveness after disconnecting; a command launched in a terminal is not proof
   of a durable startup policy.
9. Verify all five `/health` endpoints, authenticated Agent Cards, then use Chat to exercise upload and all four
   routes. Stop one worker and confirm an explicit partial/error result, then restart it and retry.
10. Record actual sandbox IDs, image digests, test results and cleanup scope. Remove only resources created
    for this module; never delete a shared SandboxGroup or resource group for convenience.

The portal flow above is documented from official sources; no placeholder Module-04 CLI commands are required.
Actual image conversion, guest startup, identity injection, model access and ingress remain cloud acceptance
steps whether the SDK helper or portal path is used.

Official references:
- [Sandbox overview](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview)
- [Disk images](https://sandboxes.azure.com/docs/sandboxes/disk-images)
- [Create sandboxes](https://sandboxes.azure.com/docs/sandboxes/sandboxes)
- [Expose ports](https://sandboxes.azure.com/docs/sandboxes/sandbox/ports)
- [Transfer files](https://sandboxes.azure.com/docs/sandboxes/sandbox/files)
- [Python SDK setup](https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-python-sdk)

## Acceptance boundary

The Bash build wrapper has an Azure-CLI-stub regression test, runnable without Azure access or Docker:

```bash
bash -n ../build-images.sh
bash tests/build-images.test.sh
```

PowerShell equivalent:

```powershell
pwsh -NoProfile -File tests\build-images.test.ps1
```

These verify five `az acr build` calls, relative Dockerfile paths, Linux platform, default/custom tags,
input errors, obsolete push-flag rejection, failure propagation and paths with spaces from a different
working directory. The stubs do not submit builds or prove registry/cloud access.

The test harness launches five independent OS processes using the real A2A SDK and real loopback HTTP/SSE.
Its model and shared SQLite repository are explicit **test fixtures**, never production configuration fallbacks.
Those tests establish service collaboration, not Azure model quality, PostgreSQL/vector compatibility,
container build correctness, Kata isolation or ACA micro-VM lifecycle. Report those checks separately.
