#!/usr/bin/env bash
set -euo pipefail
source .env
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az group create -n "$AZURE_RESOURCE_GROUP" -l "$AZURE_LOCATION" -o none
az deployment group create \
  -g "$AZURE_RESOURCE_GROUP" \
  -f infra/main.bicep \
  -p aksClusterName="$AKS_CLUSTER_NAME" acrName="$ACR_NAME" \
     storageAccountName="$STORAGE_ACCOUNT_NAME" gpuVmSize="$GPU_VM_SIZE" \
     gpuNodeCount="$GPU_NODE_COUNT"
