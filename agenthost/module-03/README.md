# Module 3 — Solution B: AKS + agent-sandbox (30 min)

[⬆ Back to Workshop Home](../readme.md)

## Overview

Deploy agents on **Azure Kubernetes Service (AKS)** using **[agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)** (kubernetes-sigs) for isolated, stateful agent runtimes with **Kata Container** Micro-VM isolation. This is the highest-control, strongest-isolation option for high-security ToB scenarios.

> **Why agent-sandbox (not E2B)?** `agent-sandbox` is a CNCF/Kubernetes-SIG project that provides a `Sandbox` CRD + controller for managing isolated, stateful, singleton agent pods with a **stable identity**, **persistent storage**, and **lifecycle management** (create / pause / resume / hibernate). Its built-in hibernation replaces the KEDA scale-to-zero.

This module **reuses the resources Module 1 already created** (it does not recreate them) and provisions the AKS cluster **into the same Module 1 resource group**:

| Reused from Module 1 | Name pattern | Used for |
|---|---|---|
| Azure Container Registry | `acragenthost<SN>` | Agent image pull (AcrPull to kubelet) |
| User-Assigned Managed Identity | `id-agenthost-<SN>` | Workload Identity federation for pods |
| Azure Managed Redis | `redis-agenthost-<SN>` | Hot state (SSL, port **10000**) |
| Azure Blob Storage | `stcagenthost<SN>` | Cold state snapshots (container `agent-state`) |
| API Management | `apim-agenthost-<SN>` | AI Gateway for model calls (`/foundry`) |

`<SN>` is the deployment suffix stored as the `deploymentSN` tag on the Module 1 resource group; `deploy.sh` reads it automatically.

## Learning Objectives

- Provision AKS with OIDC issuer + Workload Identity, reusing the Module 1 UAMI
- Install the `agent-sandbox` controller (Helm) and run the agent as a `Sandbox` CR
- Wire the agent to Module 1 Redis / Blob / APIM
- Observe agent-sandbox lifecycle (pause / resume / hibernate) as the scale-to-zero mechanism

---

## Prerequisites

- **Module 1 deployed** (Redis, Blob, APIM, ACR, UAMI) — `deploymentSN` tag present on the RG
- `az`, `kubectl`, `helm`, `git`, and Docker installed and logged in (`az login`)

---

## One-Command Deploy

```bash
cd agenthost/module-03
./deploy.sh
```

`deploy.sh` performs, end to end:

1. Read `deploymentSN` (SN) from the Module 1 resource group tag
2. Build and push the agent image to the **existing** ACR `acragenthost<SN>`
3. Deploy `aks.bicep` — creates AKS `aks-agenthost-<SN>`, federates the Module 1 UAMI, grants AcrPull (kubelet) + Storage Blob Data Contributor (UAMI)
4. Fetch AKS credentials
5. Install the **agent-sandbox controller** via Helm (with extensions)
6. Create the `agent` namespace
7. Create runtime secrets from Module 1 Redis (`:10000` SSL) / Storage / APIM gateway URL
8. Deploy the agent as a `Sandbox` custom resource
9. Wait for the Sandbox pod to become ready

Environment overrides: `RESOURCE_GROUP`, `LOCATION`, `NAMESPACE`, `SERVICE_ACCOUNT`, `IMAGE_TAG`, `AGENT_SANDBOX_VERSION`.

> Set `AGENT_SANDBOX_VERSION` to a released tag from
> https://github.com/kubernetes-sigs/agent-sandbox/releases (the chart requires `image.tag`).

---

## Manual Steps (equivalent to deploy.sh)

### Step 1 — Get the deployment suffix (SN)

```bash
RESOURCE_GROUP="rg-agenthost-workshop"
SN=$(az group show -g "$RESOURCE_GROUP" --query "tags.deploymentSN" -o tsv)

ACR_NAME="acragenthost${SN}"
IDENTITY_NAME="id-agenthost-${SN}"
REDIS_NAME="redis-agenthost-${SN}"
STORAGE_ACCOUNT="stcagenthost${SN}"
APIM_NAME="apim-agenthost-${SN}"
AKS_NAME="aks-agenthost-${SN}"
NAMESPACE="agent"
```

### Step 2 — Build and push the image to the existing ACR

```bash
az acr login --name "$ACR_NAME"
# Build context is ./agent-src (app + Dockerfile + lifecycle hook)
docker build -t "${ACR_NAME}.azurecr.io/agent-host:latest" agent-src/
docker push "${ACR_NAME}.azurecr.io/agent-host:latest"
```

> The agent application lives in [`agent-src/`](./agent-src/README.md) — a simple
> reflection-loop agent that demonstrates LLM endpoint config, `Authorization: Bearer`
> auth (static key or Workload Identity), Redis state persistence, and hibernate/resume
> recovery. See its README for local-run and API details.

### Step 3 — Deploy AKS (reusing Module 1 resources)

```bash
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file aks.bicep \
  --parameters \
      location="$(az group show -g "$RESOURCE_GROUP" --query location -o tsv)" \
      deploymentSN="$SN" \
      acrName="$ACR_NAME" \
      identityName="$IDENTITY_NAME" \
      storageAccountName="$STORAGE_ACCOUNT"

az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME" --overwrite-existing
```

### Step 4 — Install the agent-sandbox controller (Helm)

```bash
# See helm/README.md: https://github.com/kubernetes-sigs/agent-sandbox/blob/main/helm/README.md
VERSION="v0.1.0"   # pick a real release tag
git clone --depth 1 --branch "$VERSION" https://github.com/kubernetes-sigs/agent-sandbox.git

helm upgrade --install agent-sandbox ./agent-sandbox/helm/ \
  --namespace agent-sandbox-system \
  --create-namespace \
  --set image.tag="$VERSION" \
  --set controller.extensions=true \
  --wait
```

### Step 5 — Create secrets from Module 1 Redis / Storage / APIM

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Azure Managed Redis (redisEnterprise): SSL on port 10000
REDIS_HOST=$(az redisenterprise show -g "$RESOURCE_GROUP" -n "$REDIS_NAME" --query hostName -o tsv)
REDIS_KEY=$(az redisenterprise database list-keys -g "$RESOURCE_GROUP" --cluster-name "$REDIS_NAME" --query primaryKey -o tsv)

kubectl create secret generic agent-redis -n "$NAMESPACE" \
  --from-literal=connection-string="${REDIS_HOST}:10000,password=${REDIS_KEY},ssl=True,abortConnect=False" \
  --from-literal=redis-host="$REDIS_HOST" \
  --from-literal=redis-password="$REDIS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic agent-config -n "$NAMESPACE" \
  --from-literal=storage-account="$STORAGE_ACCOUNT" \
  --from-literal=blob-container="agent-state" \
  --from-literal=apim-endpoint="https://${APIM_NAME}.azure-api.net/foundry" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 6 — Deploy the agent as a Sandbox

```bash
IDENTITY_CLIENT_ID=$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" --query clientId -o tsv)

sed "s|<ACR_NAME>|${ACR_NAME}|g; s|<IMAGE_TAG>|latest|g; s|<NAMESPACE>|${NAMESPACE}|g; s|<IDENTITY_CLIENT_ID>|${IDENTITY_CLIENT_ID}|g" \
  agent-sandbox.yaml | kubectl apply -f -
```

---

## Verify

```bash
# The Sandbox CR and its pod
kubectl get sandbox,pods -n "$NAMESPACE"
kubectl wait --for=condition=Ready pod -l app=agent-host -n "$NAMESPACE" --timeout=3m

# Controller
kubectl get pods -n agent-sandbox-system
```

### Lifecycle (scale-to-zero via hibernation)

`agent-sandbox` manages the Sandbox lifecycle declaratively. Pause / resume the
Sandbox (its state persists) instead of KEDA-scaling a Deployment:

```bash
# Inspect the Sandbox status / lifecycle fields
kubectl describe sandbox agent-host -n "$NAMESPACE"
```

Refer to the [agent-sandbox docs](https://agent-sandbox.sigs.k8s.io/docs/) for pause/resume, scheduled deletion, and `SandboxWarmPool` (pre-warmed sandboxes) via the extensions API.

---

## Files in This Module

| File | Description |
|---|---|
| `deploy.sh` | End-to-end deploy: reads SN, reuses Module 1 ACR/UAMI/Redis/Storage/APIM, builds the `agent-src/` image, provisions AKS, installs agent-sandbox, deploys the Sandbox |
| `aks.bicep` | AKS cluster + Kata node pool; references existing ACR/UAMI/Storage; AcrPull, Storage RBAC, UAMI federated credential |
| `agent-sandbox.yaml` | Workload Identity ServiceAccount + Kata RuntimeClass + `Sandbox` CR + Service + NetworkPolicy |
| `agent-src/` | POC agent source: `app/main.py` (ReflectionAgent HTTP server), `Dockerfile`, `requirements.txt`, `lifecycle-hook.sh`, and a usage `README.md`. This is the image built and deployed as the Sandbox. |

---

## Architecture Notes

- **Reuse, not recreate**: `aks.bicep` references the Module 1 ACR / UAMI / Storage as `existing`; only the AKS cluster and role/federation wiring are new.
- **agent-sandbox**: the `Sandbox` CRD (`agents.x-k8s.io/v1beta1`) + controller manage the agent as an isolated, stateful, singleton pod with stable identity and lifecycle — replacing the self-built E2B Manager (which does not run on Azure).
- **Workload Identity**: the Module 1 UAMI (`id-agenthost-<SN>`) gets a federated credential trusting the AKS OIDC issuer for `system:serviceaccount:agent:agent-sa` — pods obtain Azure AD tokens with no secrets.
- **Azure Managed Redis**: Module 1 provisions `redisEnterprise` (not classic Redis); it uses **SSL port 10000**. Manifests are set accordingly.
- **AI Gateway**: model calls route through APIM at `https://apim-agenthost-<SN>.azure-api.net/foundry` (the Foundry Responses gateway from Module 1).
- **Kata Containers**: the `kata` node pool is tainted/labelled; true AKS Pod Sandboxing (`KataMshvVmIsolation`) requires enabling the preview feature.
- **Scale-to-zero**: provided by agent-sandbox hibernation (pause/resume) rather than KEDA.

---

## Next Step

Proceed to [Module 4 — Solution C: ACA Sandboxes](../module-04/README.md).

---

[⬆ Back to Workshop Home](../readme.md)
