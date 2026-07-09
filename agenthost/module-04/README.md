# Module 4 — Solution C: AKS + E2B (30 min)

## Overview

Deploy agents on **Azure Kubernetes Service (AKS)** with a self-built **E2B Sandbox Manager** and **Kata Container** Micro-VM isolation. This solution provides maximum control and the strongest isolation for high-security ToB scenarios.

## Learning Objectives

- Walk through an AKS cluster with KEDA and Kata Container runtime node pool
- Deploy the E2B Sandbox Manager and agent workload to AKS
- Observe KEDA scaling to zero and cold state restore from Blob
- Configure Kata Container resource limits and test multi-agent scaling

---

## Prerequisites

- Module 1 infrastructure deployed (Redis, Blob Storage, APIM, UAMI)
- `kubectl` and `helm` installed
- Docker CLI installed

---

## Step 1 — Set Environment Variables

```bash
export RESOURCE_GROUP="rg-agenthost-workshop"
export LOCATION="eastus"
export AKS_NAME="aks-agenthost"
export ACR_NAME="acragenthost"
export IDENTITY_NAME="id-agenthost"
export REDIS_NAME="redis-agenthost"
export STORAGE_ACCOUNT="stcagenthost"
export APIM_ENDPOINT="https://apim-agenthost.azure-api.net"
export NAMESPACE="agent"
```

---

## Step 2 — Deploy AKS Cluster via Bicep

```bash
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file aks.bicep \
  --parameters \
      location="$LOCATION" \
      aksName="$AKS_NAME" \
      acrName="$ACR_NAME" \
      identityName="$IDENTITY_NAME"
```

Or run the automated script:

```bash
chmod +x deploy.sh
./deploy.sh
```

---

## Step 3 — Configure kubectl

```bash
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --overwrite-existing
```

---

## Step 4 — Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait
```

---

## Step 5 — Deploy Agent Workloads to AKS

```bash
# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create Redis secret
REDIS_KEY=$(az redis list-keys \
  --resource-group "$RESOURCE_GROUP" \
  --name "$REDIS_NAME" \
  --query primaryKey --output tsv)
REDIS_HOST=$(az redis show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$REDIS_NAME" \
  --query hostName --output tsv)

kubectl create secret generic agent-redis \
  --namespace "$NAMESPACE" \
  --from-literal=connection-string="${REDIS_HOST}:6380,******" \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy E2B Sandbox Manager
IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query clientId --output tsv)
sed "s|<ACR_NAME>|${ACR_NAME}|g; s|<IMAGE_TAG>|${IMAGE_TAG}|g; s|<NAMESPACE>|${NAMESPACE}|g; s|<IDENTITY_CLIENT_ID>|${IDENTITY_CLIENT_ID}|g" \
  e2b-manager.yaml | kubectl apply -f -

# Deploy agent workload
sed "s|<ACR_NAME>|${ACR_NAME}|g; s|<IMAGE_TAG>|${IMAGE_TAG}|g; s|<NAMESPACE>|${NAMESPACE}|g" \
  agent-deployment.yaml | kubectl apply -f -

# Apply KEDA ScaledObject
sed "s|<NAMESPACE>|${NAMESPACE}|g" \
  keda-scaledobject.yaml | kubectl apply -f -
```

---

## Step 6 — Verify KEDA Scale-to-Zero

```bash
# Watch pod scaling
kubectl get pods -n "$NAMESPACE" -w

# After 30 min idle, pods scale to 0
# Trigger a request to observe cold start and state restore
```

---

## Files in This Module

| File | Description |
|---|---|
| `deploy.sh` | Automated bash script: AKS, ACR, KEDA, and workload deployment |
| `aks.bicep` | Bicep IaC template for AKS cluster with Kata Container node pool |
| `e2b-manager.yaml` | Kubernetes Deployment for E2B Sandbox Manager |
| `agent-deployment.yaml` | Kubernetes Deployment for agent workload |
| `keda-scaledobject.yaml` | KEDA ScaledObject for scale-to-zero based on request queue depth |
| `Dockerfile` | Container image for the agent (same as Module 3) |

---

## Architecture Notes

- **Kata Containers** provide Micro-VM isolation (hardware virtualisation) for each agent instance — stronger than gVisor but with higher overhead.
- **KEDA** scales the E2B Sandbox Manager to zero after 30 min idle; a pre-termination hook checkpoints state to Blob.
- **Azure Workload Identity** (AAD Pod Identity successor) authenticates pods to Azure services without secrets.
- **APIM** is deployed in VNet-injection mode for private connectivity to the AKS cluster.

---

## Next Step

Proceed to [Module 5 — Wrap-up and Q&A](../module-05/README.md).
