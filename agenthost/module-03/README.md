# Module 3 — Solution B: AKS + agent-sandbox (40 min)

[⬆ Back to Workshop Home](../readme.md)

## Overview

Deploy agents on **Azure Kubernetes Service (AKS)** using **official AKS Pod Sandboxing** on an **Azure Linux** Kata node pool, with **[agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)** (kubernetes-sigs) managing the agent lifecycle through `Sandbox` custom resources. This is the highest-control, most customizable option, serving both **ToB** scenarios with enterprise-specific technical requirements and **ToC** scenarios that need cost and performance tuning.

> **Note:** Unlike the hosted agent in Solution A, which runs in a Microsoft Foundry managed environment, Solution B hosts the agent in AKS Pod Sandboxing.

> **Why agent-sandbox?** `agent-sandbox` is a CNCF/Kubernetes-SIG project that provides a `Sandbox` CRD and controller for managing isolated, stateful, singleton agent pods with a **stable identity**, **persistent storage**, and **lifecycle management** (create / pause / resume / hibernate). Its built-in hibernation provides the scale-to-zero mechanism used in this module.

This module **reuses the resources created by Module 1** instead of recreating them, and provisions the AKS cluster **into the same Module 1 resource group**:

| Reused from Module 1 | Name pattern | Used for |
|---|---|---|
| Azure Container Registry | `acragenthost<SN>` | Agent image pull (AcrPull to kubelet) |
| User-Assigned Managed Identity | `id-agenthost-<SN>` | Workload Identity federation for pods |
| Azure Blob Storage | `stcagenthost<SN>` | Agent state store (JSON per agent, container `agent-state`) |
| API Management | `apim-agenthost-<SN>` | AI Gateway for model calls (`/foundry`) |

`<SN>` is the deployment suffix stored as the `deploymentSN` tag on the Module 1 resource group; `deploy.sh` reads it automatically.

## Learning Objectives

- Provision AKS with OIDC issuer + Workload Identity, then enable AKS Pod Sandboxing on an Azure Linux node pool
- Install the `agent-sandbox` controller (release manifest) and run the agent as a `Sandbox` CR
- Wire the agent to Module 1 Blob / APIM
- Observe agent-sandbox lifecycle (pause / resume / hibernate) as the scale-to-zero mechanism

---

## Prerequisites

> **Note:** Run all commands in this README from this module's root directory (`agenthost/module-03/`).

- **Module 1 deployed** (Blob, APIM, ACR, UAMI) — `deploymentSN` tag present on the RG
- `az`, `kubectl`, and Docker installed and logged in (`az login`)
- Azure CLI `2.80.0+` for AKS Pod Sandboxing support

---

## One-Command Deploy

> **Choose one deployment path:** use this One-Command flow **or** the
> [Manual Steps](#manual-steps-equivalent-to-deploysh) below. They are
> equivalent; do not run both.

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
7. Create runtime secrets from Module 1 Storage / APIM gateway URL
8. Copy `agent-sandbox.yaml.example` to `agent-sandbox.yaml`, replace placeholders, and deploy the agent as a `Sandbox` custom resource that uses AKS `kata-vm-isolation`
9. Wait for the Sandbox pod to become ready

Environment overrides: `RESOURCE_GROUP`, `LOCATION`, `NAMESPACE`, `SERVICE_ACCOUNT`, `IMAGE_TAG`, `KATA_NODEPOOL_NAME`, `KATA_NODE_VM_SIZE`, `AGENT_SANDBOX_VERSION`.

> Set `AGENT_SANDBOX_VERSION` to a released tag from
> https://github.com/kubernetes-sigs/agent-sandbox/releases (used in the release manifest URL).

After `deploy.sh` completes, jump to the [Deploy Blob Private Link](#deploy-blob-private-link-optional-if-your-storage-account-supports-public-network-access) step below.

---

## Manual Steps (equivalent to deploy.sh)

> **Alternative to One-Command Deploy:** follow these steps only if you chose
> the manual deployment path. Do not run them after `./deploy.sh`.

### Step 1 — Get the deployment suffix (SN)

```bash
RESOURCE_GROUP="rg-agenthost-workshop"
SN=$(az group show -g "$RESOURCE_GROUP" --query "tags.deploymentSN" -o tsv)

ACR_NAME="acragenthost${SN}"
IDENTITY_NAME="id-agenthost-${SN}"
STORAGE_ACCOUNT="stcagenthost${SN}"
APIM_NAME="apim-agenthost-${SN}"
AKS_NAME="aks-agenthost-${SN}"
NAMESPACE="agent"
SERVICE_ACCOUNT="agent-sa"
```

### Step 2 — Build and push the image to the existing ACR

```bash
cp agent-src/app/.env.example agent-src/app/.env
sed -i "s|<SN>|${SN}|g" agent-src/app/.env

az acr login --name "$ACR_NAME"
# Build context is ./agent-src (app + Dockerfile + lifecycle hook)
docker build -t "${ACR_NAME}.azurecr.io/agent-host:latest" agent-src/
docker push "${ACR_NAME}.azurecr.io/agent-host:latest"
```

> The agent application lives in [`agent-src/`](./agent-src/README.md) — a simple
> reflection-loop agent that demonstrates LLM endpoint config, `Authorization: Bearer`
> auth (static key or Workload Identity), Blob state persistence/recovery, and hibernate/resume
> recovery. See its README for local-run and API details.

### Step 3 — Deploy the baseline AKS cluster (reusing Module 1 resources)

```bash
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file aks.bicep \
  --parameters \
      location="$(az group show -g "$RESOURCE_GROUP" --query location -o tsv)" \
      deploymentSN="$SN" \
      aksName="$AKS_NAME" \
      acrName="$ACR_NAME" \
      identityName="$IDENTITY_NAME" \
      storageAccountName="$STORAGE_ACCOUNT" \
      namespace="$NAMESPACE" \
      serviceAccountName="$SERVICE_ACCOUNT"

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
  --min-count 1 \
  --max-count 10 \
  --os-sku AzureLinux \
  --workload-runtime KataVmIsolation \
  --node-taints "kata=true:NoSchedule" \
  --labels "kata-containers=true"

az aks update -g "$RESOURCE_GROUP" -n "$AKS_NAME"
kubectl get runtimeclass kata-vm-isolation
```

### Step 5 — Install the agent-sandbox controller (release manifest)

```bash
VERSION="v0.5.2"   # pick a real release tag
kubectl apply -f \
  "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${VERSION}/sandbox-with-extensions.yaml"

kubectl wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=2m
kubectl wait --for=condition=Ready pod -l app=agent-sandbox-controller -n agent-sandbox-system --timeout=5m
```

### Step 6 — Create secrets from Module 1 Storage / APIM

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

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
## Deploy Blob Private Link (optional if your storage account supports public network access)

If your subscription policy disables Storage public network access, you need to create a
dedicated Private Endpoint subnet in the AKS-managed VNet and deploy the Blob Private Endpoint.

> **If the Module-01 Storage account has public network access disabled, or if Azure Policy disables public network access for Storage in your environment, the AKS-managed VNet must have private connectivity to the Blob endpoint before the agent can read or write its persisted state.**

Run the following script to create private connectivity from the AKS-managed VNet to the storage account:

```bash
./deploy-storage-private-link.sh
```

> The script automatically detects the AKS-managed VNet name and asks for your confirmation before continuing. You can also check the AKS-managed VNet name in the AKS resource group `$RESOURCE_GROUP`.
>
> If the script does not pick the right AKS-managed VNet, answer **"N"** to stop it, and then explicitly provide the AKS-managed VNet name when you run the script:

```bash
VNET_NAME=<aks-vnet-name> ./deploy-storage-private-link.sh
```

If you do not explicitly provide the AKS-managed VNet name, you should see output similar to the following:
```
$ ./deploy-storage-private-link.sh
WARNING: The behavior of this command has been altered by the following extension: aks-preview
WARNING: The behavior of this command has been altered by the following extension: aks-preview
    AKS vnetSubnetId is null (expected for AKS-managed VNet). Discovering VNet in node resource group...
    No VNET_NAME input provided.
    First VNet in rg-aks-agenthost-f28a14-nodes: aks-vnet-39023097
Continue with this VNet? [y/N]: y
    Auto-selected subnet prefix for snet-private-endpoints: 10.225.0.0/24
==> Deploying Blob Private Link
    Workshop RG : rg-agenthost-workshop
    Node RG     : rg-aks-agenthost-f28a14-nodes
    VNet        : aks-vnet-39023097
    PE subnet   : snet-private-endpoints (10.225.0.0/24)
    Storage     : stcagenthostf28a14
A new Bicep release is available: v0.46.1. Upgrade now by running "az bicep upgrade".
Name                         State      Timestamp                         Mode         ResourceGroup
---------------------------  ---------  --------------------------------  -----------  ---------------------
storage-private-link-f28a14  Succeeded  2026-08-21T11:57:12.610428+00:00  Incremental  rg-agenthost-workshop
==> Blob Private Link deployed. Storage clients in the AKS VNet now resolve the Blob endpoint to the Private Endpoint IP.
```
In the Azure portal, open the storage account and confirm that the private endpoint was added:
<img style="cursor: default;" onclick="event.preventDefault(); event.stopPropagation(); return false;" src="../pic/module-03-blob-private-endpoint.png" alt="module-03-blob-private-endpoint">

> **Note:** The script creates the subnet in the AKS-managed VNet, then
> deploys the Private Endpoint and Private DNS resources in the workshop
> resource group `$RESOURCE_GROUP`. 
> 
> The agent still uses
> `https://<storage-account>.blob.core.windows.net`; Private DNS resolves that
> hostname to the Private Endpoint IP from inside the AKS VNet.
>
> The script automatically picks a free `/24` CIDR from the VNet address 
> space and creates a subnet to accommodate the private endpoint.

---

## Verify

```bash
# The Sandbox CR and its pod
kubectl get sandbox,pods -n "$NAMESPACE"
kubectl wait --for=condition=Ready pod -l app=agent-host -n "$NAMESPACE" --timeout=3m

# Controller
kubectl get pods -n agent-sandbox-system
```
You should see output like:
```
agenthost/module-03$ kubectl get sandbox,pods -n "$NAMESPACE"
NAME                                 READY   REASON              AGE
sandbox.agents.x-k8s.io/agent-host   True    DependenciesReady   2m12s

NAME             READY   STATUS    RESTARTS   AGE
pod/agent-host   1/1     Running   0          2m12s

agenthost/module-03$ kubectl get pods -n agent-sandbox-system
NAME                                        READY   STATUS    RESTARTS   AGE
agent-sandbox-controller-76885c8b6c-bk84h   1/1     Running   0          117m
```
### Verify the agent is working

Run `kubectl get all -n $NAMESPACE`; you should see output similar to the following:
```
agenthost/module-03$ kubectl get all -n $NAMESPACE
NAME             READY   STATUS    RESTARTS   AGE
pod/agent-host   1/1     Running   0          34s

NAME                 TYPE           CLUSTER-IP   EXTERNAL-IP      PORT(S)        AGE
service/agent-host-lb   LoadBalancer   10.0.63.89   135.***.***.251  80:31606/TCP   33s
```
Open `http://<EXTERNAL-IP>` in your browser. You should see the chat window. Ask several questions to confirm that the agent works:

> ***Tip: Make sure the URL includes `http://`; otherwise, the browser may default to HTTPS, which is not implemented in this workshop agent yet.***

<img style="cursor: default;" onclick="event.preventDefault(); event.stopPropagation(); return false;" src="../pic/module-03-agent-chat-portal.png" alt="module-03-agent-chat-portal">

### Verify chat history persisted to Blob

> **Tip**: If public network access is disabled on your storage account, run the verification below from a jumpbox that can reach the storage account through Private Link.
> The easiest approach in this workshop is to reuse the private connectivity you just created:
> 1. Create a separate subnet in the AKS-managed VNet.
> 2. Create a jumpbox VM in that subnet. The jumpbox will have a NIC and private IP in the subnet.
> 3. Use the jumpbox to access the storage account through the private endpoint.


After several rounds of chat, verify that the conversation state is persisted in the
`agent-state` container as `agent-host.json`. From the jumpbox browser, open the Blob container in the portal and view `agent-host.json`. The `history` field should contain your chat turns and grow after each interaction.
<img style="cursor: default;" onclick="event.preventDefault(); event.stopPropagation(); return false;" src="../pic/module-03-agent-chat-history-store-in-blob.png" alt="module-03-agent-chat-history-store-in-blob">

If your jumpbox does not have a browser, you can download the blob to view it locally:
```bash
# List state blobs (should include agent-host.json)
az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name agent-state \
  --auth-mode login \
  --query "[].name" -o tsv

# Inspect the saved chat history JSON
az storage blob download \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name agent-state \
  --name agent-host.json \
  --file /tmp/agent-host.json \
  --auth-mode login \
  --overwrite

cat /tmp/agent-host.json
```

### Verify agent runs in sandbox

Run `kubectl describe` to confirm that the pod is running in a Sandbox with runtime class **`kata-vm-isolation`**:
```
agenthost/module-03$ kubectl describe pod/agent-host -n $NAMESPACE
Name:                agent-host
Namespace:           agent
Priority:            0
Runtime Class Name:  kata-vm-isolation
Service Account:     agent-sa
Node:                aks-kata-75222809-vmss00000a/10.224.0.19
Start Time:          Tue, 21 Jul 2026 00:43:13 +0800
Labels:              agents.x-k8s.io/sandbox-name-hash=03e7e68b
                     app=agent-host
                     azure.workload.identity/use=true
                     component=agent-runtime
                     topology.kubernetes.io/region=eastus2
                     topology.kubernetes.io/zone=0
Annotations:         agents.x-k8s.io/propagated-labels: app,azure.workload.identity/use,component
Status:              Running
IP:                  10.224.0.30
IPs:
  IP:           10.224.0.30
Controlled By:  Sandbox/agent-host
Containers:
  agent-host:
    Container ID:   containerd://a8619d5c5b9eef8906c84d864e9eb6a037882b14b6e7b7a4f2b23010826d5ec3
    Image:          ......
```

### Verify Pod Sandboxing Kernel Isolation

Use `uname -r` inside the sandboxed agent pod to confirm it is running with the
AKS Pod Sandboxing runtime, then compare it with a normal pod on the cluster.

```bash
AGENT_POD=$(kubectl get pod -n "$NAMESPACE" -l app=agent-host -o jsonpath='{.items[0].metadata.name}')

# Sandbox pod: should show the Kata sandbox kernel.
kubectl exec -it -n "$NAMESPACE" "$AGENT_POD" -- uname -r

# Example expected shape:
# 6.6.137.mshv1-1.azl3

# Optional comparison: run a normal pod without kata-vm-isolation.
cat <<EOF | kubectl apply -f -
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

# Example expected shape for a normal (non-sandbox) node kernel:
# 6.8.0-1059-azure

kubectl delete pod normal-pod -n "$NAMESPACE"
```

If the agent pod reports a different kernel from the normal pod, and the agent
pod is using `runtimeClassName: kata-vm-isolation`, that confirms the workload
is running inside AKS Pod Sandboxing.

### Verify agent registers in Foundry as "prompt" agent

In the Foundry portal, open your Foundry project and go to the **Agents** tab. You should see that the agent `agenthost-reflection-agent` (defined in `.env`) is registered successfully and that its type is `prompt`:

<img style="cursor: default;" onclick="event.preventDefault(); event.stopPropagation(); return false;" src="../pic/module-03-agent-in-foundry-portal.png" alt="module-03-agent-in-foundry-portal">

### Verify that the agent reloads state after resuming

Go to the AKS portal to delete the agent pod:
<img style="cursor: default;" onclick="event.preventDefault(); event.stopPropagation(); return false;" src="../pic/module-03-delete-agent-pod-to-verify-load-state.png" alt="module-03-delete-agent-pod-to-verify-load-state">

Refresh the agent chat window in the browser. You will temporarily lose the agent connection. After the agent pod resumes, the previous chat history should load back into the new chat window.

### Lifecycle (idle suspend / resume model)

The Sandbox manifest sets `spec.operatingMode: Running` and `spec.service: true`.
`operatingMode` is the lifecycle control point:

- Patch it to `Suspended` to scale the backing pod to zero while keeping the
  Sandbox object and stable service.
- Patch it back to `Running` when traffic returns.

<details>
<summary><strong>Why auto suspend/resume is not enabled here</strong></summary>

The `Sandbox` CRD provides the `Running` / `Suspended` state transition, but it
does not provide an `idleTimeout` field and cannot inspect application requests
or decide when a user session is idle. The current public `LoadBalancer` Service also
routes directly to the agent pod. When that pod is suspended, the Service has no
ready endpoint and cannot hold the request, patch the Sandbox, wait for startup,
and retry it. Therefore the Sandbox manifest alone cannot implement "idle for 15
minutes, then wake on the next HTTP request."

KEDA is useful for scaling Deployments or `SandboxWarmPool` capacity from
metrics, but it does not by itself implement the per-Sandbox session routing and
wake-before-forward behavior required by this singleton agent.

</details>

<details>
<summary><strong>Practical implementation</strong></summary>

A production implementation places an always-running gateway in front of the
Sandbox and adds an idle sweeper. The browser calls the gateway rather than the
Sandbox LoadBalancer directly. The gateway and sweeper use Kubernetes RBAC that
allows `get`, `watch`, and `patch` on the specific Sandbox resources.

The control flow is:

1. The gateway records the last completed request time for each Sandbox. Store
   this outside the agent pod, for example in Redis or a database, because the
   pod disappears while suspended.
2. The idle sweeper periodically finds Sandboxes with no active request and no
   traffic for 15 minutes, then patches `spec.operatingMode` to `Suspended`.
3. The agent-sandbox controller terminates the backing pod while retaining the
   Sandbox object and its stable Service. This workshop's conversation state is
   already durable in Blob.
4. When new traffic arrives, the gateway resolves the target Sandbox. If it is
   suspended, the gateway patches `operatingMode` to `Running` and holds the
   incoming request.
5. The gateway watches the Sandbox until `Ready=True`, then forwards the held
   request to `status.serviceFQDN`. If startup exceeds a configured timeout, it
   returns a retriable `503` response.
6. The implementation must serialize concurrent wake requests and recheck the
   active-request count immediately before suspension, so the sweeper cannot
   suspend a Sandbox while a request is running.

For larger platforms, `SandboxTemplate`, `SandboxClaim`, and `SandboxWarmPool`
can reduce cold-start latency, but the gateway still owns session routing,
idle detection, request holding, and wake-on-traffic behavior.

</details>

#### Workshop simplification

To keep this workshop focused on Sandbox lifecycle and state recovery, it does
not deploy a custom gateway, activity store, or idle-sweeper controller. We use
manual patches to represent the two actions that those components would perform:

1. After 15 minutes without user traffic, the idle sweeper would patch the
   Sandbox to `Suspended`.
2. On the next user request, the gateway would patch the Sandbox back to
   `Running`, wait for `Ready=True`, then proxy the request to the stable
   Sandbox Service.

Run the equivalent manual suspend/resume commands:

```bash
# Suspend after an idle period (the workshop target is 15 minutes)
kubectl patch sandbox agent-host -n "$NAMESPACE" --type merge \
  -p '{"spec":{"operatingMode":"Suspended"}}'

# Resume when traffic returns
kubectl patch sandbox agent-host -n "$NAMESPACE" --type merge \
  -p '{"spec":{"operatingMode":"Running"}}'

kubectl wait sandbox agent-host -n "$NAMESPACE" --for=condition=Ready --timeout=180s
```

Inspect lifecycle status:

```bash
# Inspect the Sandbox status / lifecycle fields
kubectl describe sandbox agent-host -n "$NAMESPACE"
```

Refer to the [agent-sandbox docs](https://agent-sandbox.sigs.k8s.io/docs/) for
pause/resume, scheduled deletion, and `SandboxWarmPool` patterns.

---

## Files in This Module

| File | Description |
|---|---|
| `deploy.sh` | End-to-end deploy: reads SN, reuses Module 1 ACR/UAMI/Storage/APIM, builds the `agent-src/` image, provisions baseline AKS, enables AKS Pod Sandboxing on an Azure Linux node pool, installs agent-sandbox, and deploys the Sandbox |
| `aks.bicep` | Baseline AKS cluster; references existing ACR/UAMI/Storage; AcrPull, Storage RBAC, UAMI federated credential. The AKS Pod Sandboxing node pool is added by `deploy.sh`. |
| `deploy-storage-private-link.sh` | Optional post-AKS wrapper; discovers the AKS-managed VNet, creates a dedicated Private Endpoint subnet, and deploys the Blob Private Link Bicep. |
| `storage-private-link.bicep` | Optional Blob Private Endpoint, Private DNS zone, VNet link, and DNS zone group in the workshop resource group. |
| `agent-sandbox.yaml.example` | Template manifest with placeholders for ACR/image tag/namespace/identity values |
| `agent-sandbox.yaml` | Generated from `agent-sandbox.yaml.example` during deploy; then applied to create ServiceAccount + `Sandbox` CR + Service using AKS `kata-vm-isolation` |
| `agent-src/` | POC agent source: `app/main.py` (ReflectionAgent HTTP server), `Dockerfile`, `requirements.txt`, `lifecycle-hook.sh`, and a usage `README.md`. This is the image built and deployed as the Sandbox. |

---

## Architecture Notes

- **Reuse, not recreate**: `aks.bicep` references the Module 1 ACR / UAMI / Storage as `existing`; only the AKS cluster and role/federation wiring are new.
- **AKS Pod Sandboxing**: the sandbox node pool is created with `--os-sku AzureLinux --workload-runtime KataVmIsolation`, which gives the cluster the built-in `kata-vm-isolation` runtime class used by the agent workload.
- **agent-sandbox**: the `Sandbox` CRD (`agents.x-k8s.io/v1beta1`) + controller manage the agent as an isolated, stateful, singleton pod with stable identity and lifecycle.
- **Workload Identity**: the Module 1 UAMI (`id-agenthost-<SN>`) gets a federated credential trusting the AKS OIDC issuer for `system:serviceaccount:agent:agent-sa` — pods obtain Azure AD tokens with no secrets.
- **Azure Blob Storage**: agent conversation state is persisted directly to Blob as `<AGENT_ID>.json` (container `agent-state`) on every change; the pod recovers it on startup. Blob is the single source of truth — no Redis / hot cache.
- **AI Gateway**: model calls route through APIM at `https://apim-agenthost-<SN>.azure-api.net/foundry` (the Foundry Responses gateway from Module 1).
- **Kata Containers**: the `kata` node pool is tainted/labelled, and the agent workload targets it with `runtimeClassName: kata-vm-isolation` plus node selector / toleration.
- **Scale-to-zero**: the Sandbox exposes `operatingMode` (`Running` / `Suspended`) as the suspend/resume control point. A gateway or idle sweeper should enforce the 15-minute idle policy and wake the Sandbox before proxying returned traffic.

---

## Next Step

Proceed to [Module 4 — Solution C: ACA Sandboxes](../module-04/README.md).

---

[⬆ Back to Workshop Home](../readme.md)
