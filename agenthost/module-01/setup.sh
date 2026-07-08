#!/bin/bash
# setup.sh — Module 1: Core Infrastructure Setup
# Provisions shared Azure resources for the agent hosting workshop.
# Usage: ./setup.sh
# Set variables below or export them before running.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
LOCATION="${LOCATION:-eastus2}"
# Generate a 9-digit UTC suffix (HHmmssfff) to match main.bicep's utcNow('HHmmssfff')
if [[ -z "${DEPLOYMENT_SUFFIX:-}" ]]; then
  if date -u +%H%M%S%3N >/dev/null 2>&1; then
    DEPLOYMENT_SUFFIX="$(date -u +%H%M%S%3N)"
  elif command -v gdate >/dev/null 2>&1; then
    DEPLOYMENT_SUFFIX="$(gdate -u +%H%M%S%3N)"
  else
    echo "DEPLOYMENT_SUFFIX not set and GNU date is required. On macOS: brew install coreutils and use gdate (or export DEPLOYMENT_SUFFIX manually)." >&2
    exit 1
  fi
fi
REDIS_NAME="${REDIS_NAME:-redis-agenthost-${DEPLOYMENT_SUFFIX}}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stcagenthost${DEPLOYMENT_SUFFIX}}"
APIM_NAME="${APIM_NAME:-apim-agenthost-${DEPLOYMENT_SUFFIX}}"
APIM_PUBLISHER_EMAIL="${APIM_PUBLISHER_EMAIL:-admin@example.com}"
APIM_PUBLISHER_NAME="${APIM_PUBLISHER_NAME:-Agent Hosting Workshop}"
IDENTITY_NAME="${IDENTITY_NAME:-id-agenthost-${DEPLOYMENT_SUFFIX}}"
ENTRA_APP_NAME="${ENTRA_APP_NAME:-app-agenthost}"
KV_NAME="${KV_NAME:-kv-agenthost-${DEPLOYMENT_SUFFIX}}"
ACR_NAME="${ACR_NAME:-acragenthost${DEPLOYMENT_SUFFIX}}"
AOAI_ENDPOINT="${AOAI_ENDPOINT:-https://kacai-3055-resource.services.ai.azure.com/openai/v1}"
FOUNDRY_NAME="${FOUNDRY_NAME:-foundry-agenthost-${DEPLOYMENT_SUFFIX}}"
PROJECT_NAME="${PROJECT_NAME:-maf-agent-basic-resp}"
AZD_ENV_NAME="${AZD_ENV_NAME:-maf-agent-basic-resp-dev}"
MODEL_DEPLOYMENT_NAME="${MODEL_DEPLOYMENT_NAME:-gpt-5.4-mini}"
MODEL_VERSION="${MODEL_VERSION:-2026-03-17}"
CS_API_VERSION="2026-03-01"
APIM_API_VERSION="2023-05-01-preview"
OPENAI_USER_ROLE_ID="5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"

echo "==> [1/8] Creating Resource Group: $RESOURCE_GROUP in $LOCATION"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags deploymentSuffix="$DEPLOYMENT_SUFFIX" \
  --output none

echo "==> [2/8] Creating Azure Managed Redis (Balanced_B0): $REDIS_NAME"
az redisenterprise create \
  --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$REDIS_NAME" \
  --location "$LOCATION" \
  --sku Balanced_B0 \
  --output none

az redisenterprise database create \
  --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$REDIS_NAME" \
  --name default \
  --client-protocol Encrypted \
  --clustering-policy OSSCluster \
  --eviction-policy AllKeysLRU \
  --output none

echo "==> [3/8] Creating Azure Blob Storage account: $STORAGE_ACCOUNT"
az storage account create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --access-tier Cool \
  --output none

# Enable versioning on the default blob service
az storage account blob-service-properties update \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --enable-versioning true \
  --output none

# Create a container for cold state snapshots
az storage container create \
  --account-name "$STORAGE_ACCOUNT" \
  --name "agent-state" \
  --auth-mode login \
  --output none

echo "==> [4/8] Creating Azure API Management (Consumption SKU): $APIM_NAME"
az apim create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APIM_NAME" \
  --location "$LOCATION" \
  --publisher-email "$APIM_PUBLISHER_EMAIL" \
  --publisher-name "$APIM_PUBLISHER_NAME" \
  --sku-name Consumption \
  --output none

echo "==> [5/8] Creating Azure Key Vault (RBAC-enabled): $KV_NAME"
az keyvault create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$KV_NAME" \
  --location "$LOCATION" \
  --enable-rbac-authorization true \
  --output none

echo "==> [6/8] Creating Azure Container Registry (Standard SKU): $ACR_NAME"
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --location "$LOCATION" \
  --sku Standard \
  --output none

echo "==> [7/8] Registering Entra ID App: $ENTRA_APP_NAME"
APP_ID=$(az ad app create \
  --display-name "$ENTRA_APP_NAME" \
  --sign-in-audience AzureADMyOrg \
  --query appId \
  --output tsv)
echo "    App ID: $APP_ID"

echo "==> [8/8] Creating User-Assigned Managed Identity: $IDENTITY_NAME"
az identity create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --location "$LOCATION" \
  --output none

IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query clientId \
  --output tsv)
echo "    Identity Client ID: $IDENTITY_CLIENT_ID"

IDENTITY_PRINCIPAL_ID=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query principalId \
  --output tsv)

# ── Foundry (AIServices) stack ───────────────────────────────────────────────
# Re-implements module-01 core.bicep's Foundry resources in az CLI. Resources
# without native CLI coverage (project, Defender for AI, RAI policies, APIM
# backend/API/policy) are created with `az rest`.
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
FOUNDRY_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_NAME}"
APIM_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> [Foundry 1/9] Creating Foundry (AIServices) account: $FOUNDRY_NAME"
az cognitiveservices account create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FOUNDRY_NAME" \
  --location "$LOCATION" \
  --kind AIServices \
  --sku S0 \
  --custom-domain "$FOUNDRY_NAME" \
  --assign-identity \
  --yes \
  --output none

echo "==> [Foundry 2/9] Enabling project management and tagging the account"
az rest \
  --method patch \
  --url "https://management.azure.com${FOUNDRY_ID}?api-version=${CS_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "{\"tags\":{\"azd-env-name\":\"${AZD_ENV_NAME}\"},\"properties\":{\"allowProjectManagement\":true,\"defaultProject\":\"${PROJECT_NAME}\",\"associatedProjects\":[\"${PROJECT_NAME}\"],\"publicNetworkAccess\":\"Enabled\"}}" \
  --output none

echo "==> [Foundry 3/9] Creating RAI policies (Microsoft.Default, Microsoft.DefaultV2)"
cat > "$TMP_DIR/rai-default.json" <<'JSON'
{"properties":{"mode":"Blocking","contentFilters":[
  {"name":"Hate","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Hate","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Completion","action":"NONE"},
  {"name":"Sexual","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Sexual","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Completion","action":"NONE"},
  {"name":"Violence","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Violence","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Completion","action":"NONE"},
  {"name":"Selfharm","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Selfharm","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Completion","action":"NONE"}
]}}
JSON
az rest \
  --method put \
  --url "https://management.azure.com${FOUNDRY_ID}/raiPolicies/Microsoft.Default?api-version=${CS_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "@$TMP_DIR/rai-default.json" \
  --output none

cat > "$TMP_DIR/rai-defaultv2.json" <<'JSON'
{"properties":{"mode":"Blocking","contentFilters":[
  {"name":"Hate","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Hate","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Completion","action":"NONE"},
  {"name":"Sexual","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Sexual","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Completion","action":"NONE"},
  {"name":"Violence","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Violence","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Completion","action":"NONE"},
  {"name":"Selfharm","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Selfharm","severityThreshold":"Medium","blocking":true,"enabled":true,"source":"Completion","action":"NONE"},
  {"name":"Jailbreak","blocking":true,"enabled":true,"source":"Prompt","action":"NONE"},
  {"name":"Protected Material Text","blocking":true,"enabled":true,"source":"Completion","action":"NONE"},
  {"name":"Protected Material Code","blocking":false,"enabled":true,"source":"Completion","action":"NONE"}
]}}
JSON
az rest \
  --method put \
  --url "https://management.azure.com${FOUNDRY_ID}/raiPolicies/Microsoft.DefaultV2?api-version=${CS_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "@$TMP_DIR/rai-defaultv2.json" \
  --output none

echo "==> [Foundry 4/9] Enabling Defender for AI"
az rest \
  --method put \
  --url "https://management.azure.com${FOUNDRY_ID}/defenderForAISettings/Default?api-version=${CS_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "{\"properties\":{\"state\":\"Enabled\"}}" \
  --output none

echo "==> [Foundry 5/9] Creating project: $PROJECT_NAME"
az rest \
  --method put \
  --url "https://management.azure.com${FOUNDRY_ID}/projects/${PROJECT_NAME}?api-version=${CS_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "{\"location\":\"${LOCATION}\",\"identity\":{\"type\":\"SystemAssigned\"},\"properties\":{\"description\":\"${PROJECT_NAME} Project\",\"displayName\":\"${PROJECT_NAME}\"}}" \
  --output none

echo "==> [Foundry 6/9] Deploying model $MODEL_DEPLOYMENT_NAME (GlobalStandard, capacity 50)"
az rest \
  --method put \
  --url "https://management.azure.com${FOUNDRY_ID}/deployments/${MODEL_DEPLOYMENT_NAME}?api-version=${CS_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "{\"sku\":{\"name\":\"GlobalStandard\",\"capacity\":50},\"properties\":{\"model\":{\"format\":\"OpenAI\",\"name\":\"${MODEL_DEPLOYMENT_NAME}\",\"version\":\"${MODEL_VERSION}\"},\"versionUpgradeOption\":\"OnceNewDefaultVersionAvailable\",\"currentCapacity\":50,\"raiPolicyName\":\"Microsoft.DefaultV2\"}}" \
  --output none

echo "==> [Foundry 7/9] Disabling local auth (Entra ID only) on the account"
az rest \
  --method patch \
  --url "https://management.azure.com${FOUNDRY_ID}?api-version=${CS_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "{\"properties\":{\"disableLocalAuth\":true}}" \
  --output none

FOUNDRY_ENDPOINT="$(az cognitiveservices account show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FOUNDRY_NAME" \
  --query properties.endpoint \
  --output tsv)"

echo "==> [Foundry 8/9] Registering APIM backend and granting OpenAI User role to the UAMI"
az rest \
  --method put \
  --url "https://management.azure.com${APIM_ID}/backends/foundry-host-agent?api-version=${APIM_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "{\"properties\":{\"description\":\"Foundry AIServices inference backend for the hosted agent\",\"url\":\"${FOUNDRY_ENDPOINT}\",\"protocol\":\"http\",\"tls\":{\"validateCertificateChain\":true,\"validateCertificateName\":true}}}" \
  --output none

# Required because the account sets disableLocalAuth=true; APIM calls Foundry
# with an Entra ID token from the user-assigned managed identity.
az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "$OPENAI_USER_ROLE_ID" \
  --scope "$FOUNDRY_ID" \
  --output none

echo "==> [Foundry 9/9] Publishing the APIM AI gateway API (path /foundry)"
az rest \
  --method put \
  --url "https://management.azure.com${APIM_ID}/apis/foundry-ai-gateway?api-version=${APIM_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "{\"properties\":{\"displayName\":\"Foundry AI Gateway\",\"description\":\"AI gateway exposing the Foundry OpenAI inference endpoint through APIM with managed-identity auth.\",\"path\":\"foundry\",\"protocols\":[\"https\"],\"subscriptionRequired\":false,\"serviceUrl\":\"${FOUNDRY_ENDPOINT}openai\"}}" \
  --output none

az rest \
  --method put \
  --url "https://management.azure.com${APIM_ID}/apis/foundry-ai-gateway/operations/chat-completions?api-version=${APIM_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "{\"properties\":{\"displayName\":\"Chat Completions\",\"method\":\"POST\",\"urlTemplate\":\"/deployments/{deployment-id}/chat/completions\",\"templateParameters\":[{\"name\":\"deployment-id\",\"type\":\"string\",\"required\":true}]}}" \
  --output none

cat > "$TMP_DIR/gateway-policy.json" <<JSON
{"properties":{"format":"rawxml","value":"<policies><inbound><base /><set-backend-service backend-id=\"foundry-host-agent\" /><authentication-managed-identity resource=\"https://cognitiveservices.azure.com\" client-id=\"${IDENTITY_CLIENT_ID}\" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>"}}
JSON
az rest \
  --method put \
  --url "https://management.azure.com${APIM_ID}/apis/foundry-ai-gateway/policies/policy?api-version=${APIM_API_VERSION}" \
  --headers "Content-Type=application/json" \
  --body "@$TMP_DIR/gateway-policy.json" \
  --output none

echo ""
echo "==> Infrastructure provisioned successfully."
echo ""
echo "    Resource Group : $RESOURCE_GROUP"
echo "    Redis          : $REDIS_NAME"
echo "    Storage        : $STORAGE_ACCOUNT"
echo "    APIM           : $APIM_NAME"
echo "    Key Vault      : $KV_NAME"
echo "    ACR            : $ACR_NAME"
echo "    Entra App ID   : $APP_ID"
echo "    Identity ID    : $IDENTITY_CLIENT_ID"
echo "    Foundry        : $FOUNDRY_NAME"
echo "    Project        : $PROJECT_NAME"
echo "    Model          : $MODEL_DEPLOYMENT_NAME (GlobalStandard, cap 50)"
echo "    AI Gateway     : https://${APIM_NAME}.azure-api.net/foundry"
echo ""
echo "Next: proceed to module-02 to deploy the hosted agent with azd."
