#!/usr/bin/env bash
# deploy.sh — Module 3 (Solution B): AKS + agent-sandbox, reusing Module 1 resources
#
# Retrieves the deployment suffix (SN) from the Module 1 resource group tag,
# reuses the ACR / UAMI / Redis / Storage / APIM that Module 1 already created,
# provisions AKS (aks.bicep), installs the kubernetes-sigs/agent-sandbox
# controller (release manifest), then deploys the agent as a Sandbox custom resource.
#
# agent-sandbox: https://github.com/kubernetes-sigs/agent-sandbox
#   (replaces the earlier self-built E2B Sandbox Manager, which does not run on Azure.)
#
# Usage: ./deploy.sh
# Env overrides: RESOURCE_GROUP, LOCATION, NAMESPACE, SERVICE_ACCOUNT, IMAGE_TAG,
#                KATA_NODEPOOL_NAME, KATA_NODE_VM_SIZE, AGENT_SANDBOX_VERSION
# Prerequisites: Module 1 deployed; Docker, kubectl, az installed.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
NAMESPACE="${NAMESPACE:-agent}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-agent-sa}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
KATA_NODEPOOL_NAME="${KATA_NODEPOOL_NAME:-kata}"
KATA_NODE_VM_SIZE="${KATA_NODE_VM_SIZE:-Standard_D4s_v3}"
# LLM model deployment name. In foundry mode the persistent agent uses this model;
# inference routes through APIM via the Module 1 Foundry AI Gateway connection.
LLM_MODEL="${LLM_MODEL:-gpt-5.4-mini}"
# Foundry project (Module 1) — the persistent agent is created here, so it shows
# up in the Foundry catalog. Endpoint format matches Module 1's output.
FOUNDRY_PROJECT_NAME="${FOUNDRY_PROJECT_NAME:-maf-agent-prj}"
# Pick a released version from https://github.com/kubernetes-sigs/agent-sandbox/releases
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v0.5.2}"

echo "==> [1/9] Retrieving deployment suffix (SN) from Module 1 resource group"
SN=$(az group show --resource-group "$RESOURCE_GROUP" --query "tags.deploymentSN" --output tsv 2>/dev/null | tr -d "\r\n" || echo "")
if [ -z "$SN" ]; then
  echo "ERROR: deploymentSN tag not found on $RESOURCE_GROUP. Deploy Module 1 first."
  exit 1
fi
echo "    SN=$SN"

cp agent-src/.env.example agent-src/.env
sed -i "s|<SN>|${SN}|g" agent-src/.env

# ── Module 1 resource names (reused, never recreated) ─────────────────────────
ACR_NAME="acragenthost${SN}"
IDENTITY_NAME="id-agenthost-${SN}"
REDIS_NAME="redis-agenthost-${SN}"
STORAGE_ACCOUNT="stcagenthost${SN}"
APIM_NAME="apim-agenthost-${SN}"
AKS_NAME="aks-agenthost-${SN}"
# Foundry account/project from Module 1. The project endpoint (same format as the
# Module 1 output) is where the persistent agent is created -> Foundry catalog.
FOUNDRY_ACCOUNT="foundry-agenthost-${SN}"
FOUNDRY_PROJECT_ENDPOINT="${FOUNDRY_PROJECT_ENDPOINT:-https://${FOUNDRY_ACCOUNT}.services.ai.azure.com/api/projects/${FOUNDRY_PROJECT_NAME}}"
LOCATION="${LOCATION:-$(az group show -g "$RESOURCE_GROUP" --query location -o tsv | tr -d "\r\n")}"
# Region for the AKS cluster + its node resource group. The AKS resource is still
# created INTO the Module 1 resource group ($RESOURCE_GROUP); only its region
# differs. Override with AKS_LOCATION=<region>.
AKS_LOCATION="$LOCATION"
echo "    ACR=$ACR_NAME  UAMI=$IDENTITY_NAME  Redis=$REDIS_NAME  Storage=$STORAGE_ACCOUNT  APIM=$APIM_NAME"

echo "==> [2/9] Building and pushing the agent image to the EXISTING ACR"
# Build context is ./agent-src (contains the app, Dockerfile, and lifecycle hook).
az acr login --name "$ACR_NAME"
docker build -t "${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}" agent-src/
docker push "${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}"

echo "==> [3/9] Deploying baseline AKS (reusing ACR/UAMI/Storage) via Bicep"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file aks.bicep \
  --parameters \
      location="$AKS_LOCATION" \
      deploymentSN="$SN" \
      aksName="$AKS_NAME" \
      acrName="$ACR_NAME" \
      identityName="$IDENTITY_NAME" \
      storageAccountName="$STORAGE_ACCOUNT" \
      namespace="$NAMESPACE" \
      serviceAccountName="$SERVICE_ACCOUNT" \
  --output none

echo "==> [4/9] Enabling AKS Pod Sandboxing on an Azure Linux node pool"
if az aks nodepool show --resource-group "$RESOURCE_GROUP" --cluster-name "$AKS_NAME" --name "$KATA_NODEPOOL_NAME" --output none 2>/dev/null; then
  echo "    Node pool $KATA_NODEPOOL_NAME already exists; reusing it"
else
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
    --labels "kata-containers=true" \
    --output none
fi
az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --output none
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl get runtimeclass kata-vm-isolation >/dev/null

echo "==> [5/9] Installing the agent-sandbox controller from release manifest ($AGENT_SANDBOX_VERSION)"
# Install core + extensions in one collision-free manifest, as recommended by
# the upstream project README/docs.
AGENT_SANDBOX_MANIFEST_URL="https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox-with-extensions.yaml"
if command -v curl >/dev/null 2>&1; then
  if ! curl --fail --silent --show-error --location --head "$AGENT_SANDBOX_MANIFEST_URL" >/dev/null; then
    echo "ERROR: Cannot find release manifest for AGENT_SANDBOX_VERSION=${AGENT_SANDBOX_VERSION}"
    echo "       URL: $AGENT_SANDBOX_MANIFEST_URL"
    echo "       Check available tags: https://github.com/kubernetes-sigs/agent-sandbox/releases"
    exit 1
  fi
else
  echo "WARN: curl not found; skipping release manifest pre-check"
fi
kubectl apply -f \
  "$AGENT_SANDBOX_MANIFEST_URL"
kubectl wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=2m

echo "==> [6/9] Creating namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> [7/9] Creating runtime secrets from Module 1 Redis / Storage / APIM"
# Azure Cache for Redis: SSL on port 6380
REDIS_HOST=$(az redis show -g "$RESOURCE_GROUP" -n "$REDIS_NAME" --query hostName -o tsv | tr -d "\r\n")
REDIS_KEY=$(az redis list-keys -g "$RESOURCE_GROUP" -n "$REDIS_NAME" --query primaryKey -o tsv | tr -d "\r\n")
APIM_GATEWAY_URL="https://${APIM_NAME}.azure-api.net/foundry"

kubectl create secret generic agent-redis \
  --namespace "$NAMESPACE" \
  --from-literal=connection-string="${REDIS_HOST}:6380,password=${REDIS_KEY},ssl=True" \
  --from-literal=redis-host="$REDIS_HOST" \
  --from-literal=redis-password="$REDIS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic agent-config \
  --namespace "$NAMESPACE" \
  --from-literal=storage-account="$STORAGE_ACCOUNT" \
  --from-literal=blob-container="agent-state" \
  --from-literal=apim-endpoint="$APIM_GATEWAY_URL" \
  --from-literal=llm-model="$LLM_MODEL" \
  --from-literal=foundry-project-endpoint="$FOUNDRY_PROJECT_ENDPOINT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [8/9] Deploying the agent as a Sandbox custom resource"
# replace the placeholders in the example manifest with the actual values for this deployment
IDENTITY_CLIENT_ID=$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" --query clientId -o tsv | tr -d "\r\n")
cp agent-sandbox.yaml.example agent-sandbox.yaml
sed "s|<ACR_NAME>|${ACR_NAME}|g; s|<IMAGE_TAG>|${IMAGE_TAG}|g; s|<NAMESPACE>|${NAMESPACE}|g; s|<IDENTITY_CLIENT_ID>|${IDENTITY_CLIENT_ID}|g" \
  agent-sandbox.yaml > agent-sandbox.yaml.tmp && mv agent-sandbox.yaml.tmp agent-sandbox.yaml
kubectl apply -f agent-sandbox.yaml

echo "==> [9/9] Waiting for the Sandbox pod to become ready"
kubectl wait --for=condition=Ready pod -l app=agent-host --namespace "$NAMESPACE" --timeout=3m || true

echo ""
echo "==> Solution B (AKS + agent-sandbox) deployed, reusing Module 1 resources."
echo "    SN            : $SN"
echo "    AKS           : $AKS_NAME"
echo "    Namespace     : $NAMESPACE"
echo "    Kata pool     : $KATA_NODEPOOL_NAME ($KATA_NODE_VM_SIZE, AzureLinux, KataVmIsolation)"
echo "    agent-sandbox : $AGENT_SANDBOX_VERSION (ns agent-sandbox-system)"
echo "    ACR           : ${ACR_NAME}.azurecr.io"
echo "    Redis         : ${REDIS_HOST}:6380 (SSL)"
echo "    APIM          : $APIM_GATEWAY_URL"
echo ""
kubectl get sandbox,pods -n "$NAMESPACE"
