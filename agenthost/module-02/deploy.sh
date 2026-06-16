#!/usr/bin/env bash
# deploy.sh — Module 2: Solution A — Azure AI Foundry Host Agent
# Deploys Azure AI Foundry Hub, Project, Key Vault, and OpenClaw agent definition.
# Usage: ./deploy.sh
# Prerequisites: Module 1 infrastructure must be deployed first.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-openclaw-workshop}"
LOCATION="${LOCATION:-eastus}"
FOUNDRY_HUB_NAME="${FOUNDRY_HUB_NAME:-hub-openclaw}"
FOUNDRY_PROJECT_NAME="${FOUNDRY_PROJECT_NAME:-proj-openclaw}"
IDENTITY_NAME="${IDENTITY_NAME:-id-openclaw}"
REDIS_NAME="${REDIS_NAME:-redis-openclaw}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stcopenclaw}"
KV_NAME="${KV_NAME:-kv-openclaw}"
APIM_ENDPOINT="${APIM_ENDPOINT:-}"

echo "==> [1/5] Deploying Azure Key Vault: $KV_NAME"
az keyvault create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$KV_NAME" \
  --location "$LOCATION" \
  --enable-rbac-authorization true \
  --output none

# Store Redis connection string in Key Vault
echo "==> [2/5] Storing Redis connection string in Key Vault"
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

az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name "redis-connection-string" \
  --value "${REDIS_HOST}:6380,${REDIS_KEY},ssl=True,abortConnect=False" \
  --output none

# Grant the UAMI read access to Key Vault secrets
IDENTITY_PRINCIPAL=$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IDENTITY_NAME" \
  --query principalId \
  --output tsv)

KV_SCOPE=$(az keyvault show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$KV_NAME" \
  --query id \
  --output tsv)

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "$KV_SCOPE" \
  --output none

echo "==> [3/5] Deploying Azure AI Foundry Hub and Project via Bicep"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file foundry.bicep \
  --parameters \
      location="$LOCATION" \
      hubName="$FOUNDRY_HUB_NAME" \
      projectName="$FOUNDRY_PROJECT_NAME" \
      identityName="$IDENTITY_NAME" \
      storageAccountName="$STORAGE_ACCOUNT" \
      keyVaultName="$KV_NAME" \
  --output none

echo "==> [4/5] Deploying OpenClaw agent definition"
az ml agent create \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$FOUNDRY_PROJECT_NAME" \
  --file agent-definition.json \
  --output none || {
  echo "    Note: az ml agent CLI extension not found."
  echo "    Install it with: az extension add --name ml"
  echo "    Or deploy via the Azure Portal: AI Foundry > Project > Agents > New Agent"
}

echo "==> [5/5] Granting UAMI Blob Data Contributor role on Storage"
STORAGE_SCOPE=$(az storage account show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" \
  --query id \
  --output tsv)

az role assignment create \
  --assignee-object-id "$IDENTITY_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_SCOPE" \
  --output none

echo ""
echo "==> Solution A (Foundry Host Agent) deployed successfully."
echo ""
echo "    Foundry Hub     : $FOUNDRY_HUB_NAME"
echo "    Foundry Project : $FOUNDRY_PROJECT_NAME"
echo "    Key Vault       : $KV_NAME"
echo ""
echo "Next: test LLM call via APIM endpoint: $APIM_ENDPOINT"
