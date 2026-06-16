#!/usr/bin/env bash
# deploy.sh — Module 4: Solution C — AKS + E2B
# Provisions AKS cluster with Kata Container node pool, installs KEDA,
# deploys E2B Sandbox Manager and OpenClaw workload.
# Usage: ./deploy.sh
# Prerequisites: Module 1 infrastructure must be deployed first.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-openclaw-workshop}"
LOCATION="${LOCATION:-eastus}"
AKS_NAME="${AKS_NAME:-aks-openclaw}"
ACR_NAME="${ACR_NAME:-acropenclaw}"
IDENTITY_NAME="${IDENTITY_NAME:-id-openclaw}"
REDIS_NAME="${REDIS_NAME:-redis-openclaw}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stcopenclaw}"
APIM_ENDPOINT="${APIM_ENDPOINT:-}"
NAMESPACE="${NAMESPACE:-openclaw}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "==> [1/8] Creating Azure Container Registry (if not exists): $ACR_NAME"
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --location "$LOCATION" \
  --sku Basic \
  --admin-enabled false \
  --output none 2>/dev/null || echo "    ACR already exists."

echo "==> [2/8] Building and pushing OpenClaw image to ACR"
az acr login --name "$ACR_NAME"
docker build -t "${ACR_NAME}.azurecr.io/openclaw-agent:${IMAGE_TAG}" .
docker push "${ACR_NAME}.azurecr.io/openclaw-agent:${IMAGE_TAG}"

echo "==> [3/8] Deploying AKS cluster via Bicep"
IDENTITY_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query id \
  --output tsv)

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file aks.bicep \
  --parameters \
      location="$LOCATION" \
      aksName="$AKS_NAME" \
      acrName="$ACR_NAME" \
      identityId="$IDENTITY_ID" \
  --output none

echo "==> [4/8] Getting AKS credentials"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --overwrite-existing

echo "==> [5/8] Installing KEDA via Helm"
helm repo add kedacore https://kedacore.github.io/charts --force-update
helm repo update
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait \
  --timeout 5m

echo "==> [6/8] Creating Kubernetes namespace and secrets"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

REDIS_KEY=$(az redis list-keys \
  --resource-group "$RESOURCE_GROUP" \
  --name "$REDIS_NAME" \
  --query primaryKey \
  --output tsv)

REDIS_HOST=$(az redis show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$REDIS_NAME" \
  --query hostName \
  --output tsv)

kubectl create secret generic openclaw-redis \
  --namespace "$NAMESPACE" \
  --from-literal=connection-string="${REDIS_HOST}:6380,******" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic openclaw-config \
  --namespace "$NAMESPACE" \
  --from-literal=storage-account="$STORAGE_ACCOUNT" \
  --from-literal=blob-container="openclaw-state" \
  --from-literal=apim-endpoint="$APIM_ENDPOINT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [7/8] Deploying E2B Sandbox Manager and OpenClaw workload"
# Replace ACR_NAME placeholder in manifests
sed "s|<ACR_NAME>|${ACR_NAME}|g; s|<IMAGE_TAG>|${IMAGE_TAG}|g; s|<NAMESPACE>|${NAMESPACE}|g" \
  e2b-manager.yaml | kubectl apply -f -

sed "s|<ACR_NAME>|${ACR_NAME}|g; s|<IMAGE_TAG>|${IMAGE_TAG}|g; s|<NAMESPACE>|${NAMESPACE}|g" \
  openclaw-deployment.yaml | kubectl apply -f -

kubectl apply -f keda-scaledobject.yaml

echo "==> [8/8] Waiting for E2B Manager to be ready"
kubectl rollout status deployment/e2b-sandbox-manager \
  --namespace "$NAMESPACE" \
  --timeout=3m

echo ""
echo "==> Solution C (AKS + E2B) deployed successfully."
echo ""
echo "    AKS Cluster : $AKS_NAME"
echo "    Namespace   : $NAMESPACE"
echo ""
kubectl get pods -n "$NAMESPACE"
