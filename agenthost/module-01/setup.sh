#!/bin/bash
# setup.sh — Module 1: Core Infrastructure Setup
# Provisions shared Azure resources for the agent hosting workshop.
# Usage: ./setup.sh
# Set variables below or export them before running.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
LOCATION="${LOCATION:-eastus2}"
DEPLOYMENT_SUFFIX="${DEPLOYMENT_SUFFIX:-$(date -u +%H%M%S%3N)}" # requires GNU date (Linux/Azure Cloud Shell); on macOS install coreutils: brew install coreutils
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
echo ""
echo "Next: apply apim-policy.xml to APIM and proceed to module-02."
