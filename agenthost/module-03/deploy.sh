#!/usr/bin/env bash
# deploy.sh — Module 3 (Solution B): AKS + agent-sandbox, reusing Module 1 resources
#
# Retrieves the deployment suffix (SN) from the Module 1 resource group tag,
# reuses the ACR / UAMI / Redis / Storage / APIM that Module 1 already created,
# provisions AKS (aks.bicep), installs the kubernetes-sigs/agent-sandbox
# controller (Helm), then deploys the agent as a Sandbox custom resource.
#
# agent-sandbox: https://github.com/kubernetes-sigs/agent-sandbox
#   (replaces the earlier self-built E2B Sandbox Manager, which does not run on Azure.)
#
# Usage: ./deploy.sh
# Env overrides: RESOURCE_GROUP, LOCATION, NAMESPACE, SERVICE_ACCOUNT, IMAGE_TAG,
#                AGENT_SANDBOX_VERSION
# Prerequisites: Module 1 deployed; Docker, kubectl, helm, git, az installed.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
NAMESPACE="${NAMESPACE:-agent}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-agent-sa}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
# LLM model deployment name. In foundry mode the persistent agent uses this model;
# inference routes through APIM via the Module 1 Foundry AI Gateway connection.
LLM_MODEL="${LLM_MODEL:-gpt-5.4-mini}"
# Foundry project (Module 1) — the persistent agent is created here, so it shows
# up in the Foundry catalog. Endpoint format matches Module 1's output.
FOUNDRY_PROJECT_NAME="${FOUNDRY_PROJECT_NAME:-maf-agent-prj}"
# Pick a released version from https://github.com/kubernetes-sigs/agent-sandbox/releases
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v0.1.0}"

echo "==> [1/9] Retrieving deployment suffix (SN) from Module 1 resource group"
SN=$(az group show --resource-group "$RESOURCE_GROUP" --query "tags.deploymentSN" --output tsv 2>/dev/null | tr -d "\r\n" || echo "")
if [ -z "$SN" ]; then
  echo "ERROR: deploymentSN tag not found on $RESOURCE_GROUP. Deploy Module 1 first."
  exit 1
fi
echo "    SN=$SN"

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
AKS_LOCATION="${AKS_LOCATION:-eastus2}"
echo "    ACR=$ACR_NAME  UAMI=$IDENTITY_NAME  Redis=$REDIS_NAME  Storage=$STORAGE_ACCOUNT  APIM=$APIM_NAME"

echo "==> [2/9] Building and pushing the agent image to the EXISTING ACR"
# Build context is ./agent-src (contains the app, Dockerfile, and lifecycle hook).
az acr login --name "$ACR_NAME"
docker build -t "${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}" agent-src/
docker push "${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}"

echo "==> [3/9] Deploying AKS (reusing ACR/UAMI/Storage) via Bicep"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file aks.bicep \
  --parameters \
      location="$AKS_LOCATION" \
      deploymentSN="$SN" \
      acrName="$ACR_NAME" \
      identityName="$IDENTITY_NAME" \
      storageAccountName="$STORAGE_ACCOUNT" \
      namespace="$NAMESPACE" \
      serviceAccountName="$SERVICE_ACCOUNT" \
  --output none

IDENTITY_CLIENT_ID=$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" --query clientId -o tsv | tr -d "\r\n")

echo "==> [4/9] Getting AKS credentials"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing

echo "==> [5/9] Installing the agent-sandbox controller via Helm ($AGENT_SANDBOX_VERSION)"
# The Helm chart lives inside the repo (./helm). Clone it, then install the
# controller with extensions (SandboxTemplate / SandboxClaim / SandboxWarmPool).
WORKDIR="$(mktemp -d)"
git clone --depth 1 --branch "$AGENT_SANDBOX_VERSION" \
  https://github.com/kubernetes-sigs/agent-sandbox.git "$WORKDIR/agent-sandbox"
helm upgrade --install agent-sandbox "$WORKDIR/agent-sandbox/helm/" \
  --namespace agent-sandbox-system \
  --create-namespace \
  --set image.tag="$AGENT_SANDBOX_VERSION" \
  --set controller.extensions=true \
  --wait --timeout 5m
rm -rf "$WORKDIR"

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
sed "s|<ACR_NAME>|${ACR_NAME}|g; s|<IMAGE_TAG>|${IMAGE_TAG}|g; s|<NAMESPACE>|${NAMESPACE}|g; s|<IDENTITY_CLIENT_ID>|${IDENTITY_CLIENT_ID}|g" \
  agent-sandbox.yaml | kubectl apply -f -

echo "==> [9/9] Waiting for the Sandbox pod to become ready"
kubectl wait --for=condition=Ready pod -l app=agent-host --namespace "$NAMESPACE" --timeout=3m || true

echo ""
echo "==> Solution B (AKS + agent-sandbox) deployed, reusing Module 1 resources."
echo "    SN            : $SN"
echo "    AKS           : $AKS_NAME"
echo "    Namespace     : $NAMESPACE"
echo "    agent-sandbox : $AGENT_SANDBOX_VERSION (ns agent-sandbox-system)"
echo "    ACR           : ${ACR_NAME}.azurecr.io"
echo "    Redis         : ${REDIS_HOST}:6380 (SSL)"
echo "    APIM          : $APIM_GATEWAY_URL"
echo ""
kubectl get sandbox,pods -n "$NAMESPACE"
