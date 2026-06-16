#!/usr/bin/env bash
# setup.sh — Module 1: Core Infrastructure Setup
# Provisions shared Azure resources for the OpenClaw workshop.
# Usage: ./setup.sh
# Set variables below or export them before running.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-openclaw-workshop}"
LOCATION="${LOCATION:-eastus}"
REDIS_NAME="${REDIS_NAME:-redis-openclaw}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stcopenclaw}"
APIM_NAME="${APIM_NAME:-apim-openclaw}"
APIM_PUBLISHER_EMAIL="${APIM_PUBLISHER_EMAIL:-admin@example.com}"
APIM_PUBLISHER_NAME="${APIM_PUBLISHER_NAME:-OpenClaw Workshop}"
IDENTITY_NAME="${IDENTITY_NAME:-id-openclaw}"
ENTRA_APP_NAME="${ENTRA_APP_NAME:-app-openclaw}"
AOAI_ENDPOINT="${AOAI_ENDPOINT:-}"

echo "==> [1/6] Creating Resource Group: $RESOURCE_GROUP in $LOCATION"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

echo "==> [2/6] Creating Azure Managed Redis (Basic SKU): $REDIS_NAME"
az redis create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$REDIS_NAME" \
  --location "$LOCATION" \
  --sku Basic \
  --vm-size c0 \
  --output none

echo "==> [3/6] Creating Azure Blob Storage account: $STORAGE_ACCOUNT"
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
  --name "openclaw-state" \
  --auth-mode login \
  --output none

echo "==> [4/6] Creating Azure API Management (Consumption SKU): $APIM_NAME"
az apim create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APIM_NAME" \
  --location "$LOCATION" \
  --publisher-email "$APIM_PUBLISHER_EMAIL" \
  --publisher-name "$APIM_PUBLISHER_NAME" \
  --sku-name Consumption \
  --output none

echo "==> [5/6] Registering Entra ID App: $ENTRA_APP_NAME"
APP_ID=$(az ad app create \
  --display-name "$ENTRA_APP_NAME" \
  --sign-in-audience AzureADMyOrg \
  --query appId \
  --output tsv)
echo "    App ID: $APP_ID"

echo "==> [6/6] Creating User-Assigned Managed Identity: $IDENTITY_NAME"
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
echo "    Entra App ID   : $APP_ID"
echo "    Identity ID    : $IDENTITY_CLIENT_ID"
echo ""
echo "Next: apply apim-policy.xml to APIM and proceed to module-02."
