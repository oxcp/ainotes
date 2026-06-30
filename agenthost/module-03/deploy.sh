#!/usr/bin/env bash
# deploy.sh — Module 3: Solution B — ACA Sandbox
# Creates ACR, builds and pushes the agent image, deploys ACA Environment
# with Sandbox feature, and configures the ACA App with scale-to-zero lifecycle hook.
# Usage: ./deploy.sh
# Prerequisites: Module 1 infrastructure must be deployed first.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
LOCATION="${LOCATION:-eastus}"
ACR_NAME="${ACR_NAME:-acragenthost}"
ACA_ENV_NAME="${ACA_ENV_NAME:-aca-env-agenthost}"
ACA_APP_NAME="${ACA_APP_NAME:-agent-host}"
REDIS_NAME="${REDIS_NAME:-redis-agenthost}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stcagenthost}"
IDENTITY_NAME="${IDENTITY_NAME:-id-agenthost}"
APIM_ENDPOINT="${APIM_ENDPOINT:-}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "==> [1/6] Creating Azure Container Registry (if not exists): $ACR_NAME"
if ! az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --output none 2>/dev/null; then
  az acr create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --location "$LOCATION" \
    --sku Basic \
    --admin-enabled false \
    --output none
fi

echo "==> [2/6] Building and pushing agent container image"
az acr login --name "$ACR_NAME"
docker build -t "${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}" .
docker push "${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}"

echo "==> [3/6] Retrieving Redis connection string and Storage key"
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

REDIS_CONN="${REDIS_HOST}:6380,${REDIS_KEY},ssl=True,abortConnect=False"

echo "==> [4/6] Granting AcrPull role to UAMI"
IDENTITY_PRINCIPAL=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query principalId \
  --output tsv)

ACR_ID=$(az acr show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --query id \
  --output tsv)

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "AcrPull" \
  --scope "$ACR_ID" \
  --output none

IDENTITY_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query id \
  --output tsv)

echo "==> [5/6] Deploying ACA Environment and App via Bicep"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file aca.bicep \
  --parameters \
      location="$LOCATION" \
      acrName="$ACR_NAME" \
      acaEnvName="$ACA_ENV_NAME" \
      acaAppName="$ACA_APP_NAME" \
      identityId="$IDENTITY_ID" \
      identityClientId="$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query clientId --output tsv)" \
      redisConnectionString="$REDIS_CONN" \
      storageAccountName="$STORAGE_ACCOUNT" \
      apimEndpoint="$APIM_ENDPOINT" \
      imageTag="$IMAGE_TAG" \
  --output none

echo "==> [6/6] Retrieving ACA App FQDN"
ACA_FQDN=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACA_APP_NAME" \
  --query properties.configuration.ingress.fqdn \
  --output tsv)

echo ""
echo "==> Solution B (ACA Sandbox) deployed successfully."
echo ""
echo "    ACR              : ${ACR_NAME}.azurecr.io"
echo "    ACA Environment  : $ACA_ENV_NAME"
echo "    ACA App          : $ACA_APP_NAME"
echo "    App URL          : https://$ACA_FQDN"
echo ""
echo "Test with: curl -X POST https://$ACA_FQDN/chat -H 'Content-Type: application/json' -d '{\"message\":\"hello\"}'"
