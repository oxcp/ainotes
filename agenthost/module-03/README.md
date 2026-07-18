# Module 3 — Solution B: AKS + agent-sandbox (30 min)

[⬆ Back to Workshop Home](../readme.md)

## Overview

Deploy agents on **Azure Kubernetes Service (AKS)** using **official AKS Pod Sandboxing** on an **Azure Linux** Kata node pool, with **[agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)** (kubernetes-sigs) managing the agent lifecycle as `Sandbox` custom resources. This is the highest-control, strongest-isolation option for high-security ToB scenarios.

> **Why agent-sandbox?** `agent-sandbox` is a CNCF/Kubernetes-SIG project that provides a `Sandbox` CRD + controller for managing isolated, stateful, singleton agent pods with a **stable identity**, **persistent storage**, and **lifecycle management** (create / pause / resume / hibernate). Its built-in hibernation replaces the KEDA scale-to-zero.

This module **reuses the resources Module 1 already created** (it does not recreate them) and provisions the AKS cluster **into the same Module 1 resource group**:

| Reused from Module 1 | Name pattern | Used for |
|---|---|---|
| Azure Container Registry | `acragenthost<SN>` | Agent image pull (AcrPull to kubelet) |
| User-Assigned Managed Identity | `id-agenthost-<SN>` | Workload Identity federation for pods |
| Azure Cache for Redis | `redis-agenthost-<SN>` | Hot state (SSL, port **6380**) |
| Azure Blob Storage | `stcagenthost<SN>` | Cold state snapshots (container `agent-state`) |
| API Management | `apim-agenthost-<SN>` | AI Gateway for model calls (`/foundry`) |

`<SN>` is the deployment suffix stored as the `deploymentSN` tag on the Module 1 resource group; `deploy.sh` reads it automatically.

## Learning Objectives

- Provision AKS with OIDC issuer + Workload Identity, then enable AKS Pod Sandboxing on an Azure Linux node pool
- Install the `agent-sandbox` controller (release manifest) and run the agent as a `Sandbox` CR
- Wire the agent to Module 1 Redis / Blob / APIM
- Observe agent-sandbox lifecycle (pause / resume / hibernate) as the scale-to-zero mechanism

---

## Prerequisites

- **Module 1 deployed** (Redis, Blob, APIM, ACR, UAMI) — `deploymentSN` tag present on the RG
- `az`, `kubectl`, and Docker installed and logged in (`az login`)
- Azure CLI `2.80.0+` for AKS Pod Sandboxing support

---

## One-Command Deploy

```bash
cd agenthost/module-03
./deploy.sh
```

`deploy.sh` performs, end to end:

1. Read `deploymentSN` (SN) from the Module 1 resource group tag
2. Build and push the agent image to the **existing** ACR `acragenthost<SN>`
3. Deploy `aks.bicep` — creates the baseline AKS `aks-agenthost-<SN>`, federates the Module 1 UAMI, grants AcrPull (kubelet) + Storage Blob Data Contributor (UAMI)
4. Add an Azure Linux `kata` node pool with `KataVmIsolation`, run `az aks update`, and fetch AKS credentials
5. Install the **agent-sandbox controller** from release manifest (core + extensions)
6. Create the `agent` namespace
7. Create runtime secrets from Module 1 Redis (`:6380` SSL) / Storage / APIM gateway URL
8. Copy `agent-sandbox.yaml.example` to `agent-sandbox.yaml`, replace placeholders, and deploy the agent as a `Sandbox` custom resource that uses AKS `kata-vm-isolation`
9. Wait for the Sandbox pod to become ready

Environment overrides: `RESOURCE_GROUP`, `LOCATION`, `NAMESPACE`, `SERVICE_ACCOUNT`, `IMAGE_TAG`, `KATA_NODEPOOL_NAME`, `KATA_NODE_VM_SIZE`, `AGENT_SANDBOX_VERSION`.

> Set `AGENT_SANDBOX_VERSION` to a released tag from
> https://github.com/kubernetes-sigs/agent-sandbox/releases (used in the release manifest URL).

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

sed -i "s|<SN>|${SN}|g" agent-src/.env
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

### Step 3 — Deploy the baseline AKS cluster (reusing Module 1 resources)

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

### Step 4 — Enable AKS Pod Sandboxing on an Azure Linux node pool

```bash
KATA_NODEPOOL_NAME="kata"
KATA_NODE_VM_SIZE="Standard_D4s_v3"

az aks nodepool add \
  --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$AKS_NAME" \
  --name "$KATA_NODEPOOL_NAME" \
  --mode User \
  --node-vm-size "$KATA_NODE_VM_SIZE" \
  --node-count 1 \
  --enable-cluster-autoscaler \
  --min-count 0 \
  --max-count 10 \
  --os-sku AzureLinux \
  --workload-runtime KataVmIsolation \
  --node-taints "kata=true:NoSchedule" \
  --labels "kata-containers=true"

az aks update -g "$RESOURCE_GROUP" -n "$AKS_NAME"
az aks get-credentials -g "$RESOURCE_GROUP" -n "$AKS_NAME" --overwrite-existing
kubectl get runtimeclass kata-vm-isolation
```

### Step 5 — Install the agent-sandbox controller (release manifest)

```bash
VERSION="v0.5.2"   # pick a real release tag
kubectl apply -f \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${VERSION}/sandbox-with-extensions.yaml"

kubectl wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=2m
```

### Step 6 — Create secrets from Module 1 Redis / Storage / APIM

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Azure Cache for Redis: SSL on port 6380
REDIS_HOST=$(az redis show -g "$RESOURCE_GROUP" -n "$REDIS_NAME" --query hostName -o tsv)
REDIS_KEY=$(az redis list-keys -g "$RESOURCE_GROUP" -n "$REDIS_NAME" --query primaryKey -o tsv)

kubectl create secret generic agent-redis -n "$NAMESPACE" \
  --from-literal=connection-string="${REDIS_HOST}:6380,password=${REDIS_KEY},ssl=True" \
  --from-literal=redis-host="$REDIS_HOST" \
  --from-literal=redis-password="$REDIS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic agent-config -n "$NAMESPACE" \
  --from-literal=storage-account="$STORAGE_ACCOUNT" \
  --from-literal=blob-container="agent-state" \
  --from-literal=apim-endpoint="https://${APIM_NAME}.azure-api.net/foundry" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 7 — Deploy the agent as a Sandbox

```bash
IDENTITY_CLIENT_ID=$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" --query clientId -o tsv)

cp agent-sandbox.yaml.example agent-sandbox.yaml

sed "s|<ACR_NAME>|${ACR_NAME}|g; s|<IMAGE_TAG>|latest|g; s|<NAMESPACE>|${NAMESPACE}|g; s|<IDENTITY_CLIENT_ID>|${IDENTITY_CLIENT_ID}|g" \
  agent-sandbox.yaml > agent-sandbox.yaml.tmp && mv agent-sandbox.yaml.tmp agent-sandbox.yaml

kubectl apply -f agent-sandbox.yaml
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

### Verify Pod Sandboxing Kernel Isolation

Use `uname -r` inside the sandboxed agent pod to confirm it is running with the
AKS Pod Sandboxing runtime, then compare it with a normal pod on the cluster.

```bash
AGENT_POD=$(kubectl get pod -n "$NAMESPACE" -l app=agent-host -o jsonpath='{.items[0].metadata.name}')

# Sandbox pod: should show the Kata sandbox kernel.
kubectl exec -it -n "$NAMESPACE" "$AGENT_POD" -- uname -r

# Example expected shape:
# 6.6.96.mshv1

# Optional comparison: run a normal pod without kata-vm-isolation.
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: normal-pod
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: normal
      image: mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11
      command: ["/bin/sh", "-ec", "sleep 3600"]
EOF

kubectl wait --for=condition=Ready pod/normal-pod -n "$NAMESPACE" --timeout=2m
kubectl exec -it -n "$NAMESPACE" normal-pod -- uname -r

# Example expected shape for a normal Azure Linux node kernel:
# 6.6.100.mshv1-1.azl3

kubectl delete pod normal-pod -n "$NAMESPACE"
```

If the agent pod reports a different kernel from the normal pod, and the agent
pod is using `runtimeClassName: kata-vm-isolation`, that confirms the workload
is running inside AKS Pod Sandboxing.

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
| `deploy.sh` | End-to-end deploy: reads SN, reuses Module 1 ACR/UAMI/Redis/Storage/APIM, builds the `agent-src/` image, provisions baseline AKS, enables AKS Pod Sandboxing on an Azure Linux node pool, installs agent-sandbox, and deploys the Sandbox |
| `aks.bicep` | Baseline AKS cluster; references existing ACR/UAMI/Storage; AcrPull, Storage RBAC, UAMI federated credential. The AKS Pod Sandboxing node pool is added by `deploy.sh`. |
| `agent-sandbox.yaml.example` | Template manifest with placeholders for ACR/image tag/namespace/identity values |
| `agent-sandbox.yaml` | Generated from `agent-sandbox.yaml.example` during deploy; then applied to create ServiceAccount + `Sandbox` CR + Service + NetworkPolicy using AKS `kata-vm-isolation` |
| `agent-src/` | POC agent source: `app/main.py` (ReflectionAgent HTTP server), `Dockerfile`, `requirements.txt`, `lifecycle-hook.sh`, and a usage `README.md`. This is the image built and deployed as the Sandbox. |

---

## Architecture Notes

- **Reuse, not recreate**: `aks.bicep` references the Module 1 ACR / UAMI / Storage as `existing`; only the AKS cluster and role/federation wiring are new.
- **AKS Pod Sandboxing**: the sandbox node pool is created with `--os-sku AzureLinux --workload-runtime KataVmIsolation`, which gives the cluster the built-in `kata-vm-isolation` runtime class used by the agent workload.
- **agent-sandbox**: the `Sandbox` CRD (`agents.x-k8s.io/v1beta1`) + controller manage the agent as an isolated, stateful, singleton pod with stable identity and lifecycle.
- **Workload Identity**: the Module 1 UAMI (`id-agenthost-<SN>`) gets a federated credential trusting the AKS OIDC issuer for `system:serviceaccount:agent:agent-sa` — pods obtain Azure AD tokens with no secrets.
- **Azure Cache for Redis**: Module 1 provisions classic Azure Cache for Redis; it uses **SSL port 6380**. Manifests are set accordingly.
- **AI Gateway**: model calls route through APIM at `https://apim-agenthost-<SN>.azure-api.net/foundry` (the Foundry Responses gateway from Module 1).
- **Kata Containers**: the `kata` node pool is tainted/labelled, and the agent workload targets it with `runtimeClassName: kata-vm-isolation` plus node selector / toleration.
- **Scale-to-zero**: provided by agent-sandbox hibernation (pause/resume) rather than KEDA.

---

## Next Step

Proceed to [Module 4 — Solution C: ACA Sandboxes](../module-04/README.md).

---

[⬆ Back to Workshop Home](../readme.md)
