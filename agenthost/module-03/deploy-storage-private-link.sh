#!/usr/bin/env bash
# Optional post-AKS deployment for private Blob connectivity.
# Usage: PRIVATE_ENDPOINT_SUBNET_PREFIX=<unused-cidr> ./deploy-storage-private-link.sh

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
PRIVATE_ENDPOINT_SUBNET_PREFIX="${PRIVATE_ENDPOINT_SUBNET_PREFIX:-}"

if [ -z "$PRIVATE_ENDPOINT_SUBNET_PREFIX" ]; then
  echo "ERROR: Set PRIVATE_ENDPOINT_SUBNET_PREFIX to an unused CIDR inside the AKS-managed VNet."
  echo "Example: PRIVATE_ENDPOINT_SUBNET_PREFIX=10.250.0.0/24 ./deploy-storage-private-link.sh"
  exit 1
fi

SN=$(az group show --resource-group "$RESOURCE_GROUP" --query "tags.deploymentSN" --output tsv 2>/dev/null | tr -d "\r\n" || echo "")
if [ -z "$SN" ]; then
  echo "ERROR: deploymentSN tag not found on $RESOURCE_GROUP. Deploy Module 1 first."
  exit 1
fi

AKS_NAME="${AKS_NAME:-aks-agenthost-${SN}}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stcagenthost${SN}}"
NODE_RESOURCE_GROUP=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --query nodeResourceGroup --output tsv | tr -d "\r\n")
AKS_SUBNET_ID=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --query "agentPoolProfiles[0].vnetSubnetId" --output tsv | tr -d "\r\n")

if [ -n "$AKS_SUBNET_ID" ] && [ "$AKS_SUBNET_ID" != "null" ]; then
  VNET_NAME=$(printf '%s' "$AKS_SUBNET_ID" | awk -F/ '{for (i=1; i<=NF; i++) if ($i == "virtualNetworks") {print $(i+1); exit}}')
else
  VNET_COUNT=$(az network vnet list --resource-group "$NODE_RESOURCE_GROUP" --query "length(@)" --output tsv | tr -d "\r\n")
  if [ "$VNET_COUNT" != "1" ]; then
    echo "ERROR: Expected one AKS-managed VNet in $NODE_RESOURCE_GROUP, found $VNET_COUNT."
    echo "Set AKS_NAME explicitly or inspect the node resource group before retrying."
    exit 1
  fi
  VNET_NAME=$(az network vnet list --resource-group "$NODE_RESOURCE_GROUP" --query "[0].name" --output tsv | tr -d "\r\n")
fi

LOCATION=$(az network vnet show --resource-group "$NODE_RESOURCE_GROUP" --name "$VNET_NAME" --query location --output tsv | tr -d "\r\n")
VNET_ID=$(az network vnet show --resource-group "$NODE_RESOURCE_GROUP" --name "$VNET_NAME" --query id --output tsv | tr -d "\r\n")
PRIVATE_ENDPOINT_SUBNET_NAME="${PRIVATE_ENDPOINT_SUBNET_NAME:-snet-private-endpoints}"
PRIVATE_ENDPOINT_SUBNET_ID="${VNET_ID}/subnets/${PRIVATE_ENDPOINT_SUBNET_NAME}"

echo "==> Deploying Blob Private Link"
echo "    Workshop RG : $RESOURCE_GROUP"
echo "    Node RG     : $NODE_RESOURCE_GROUP"
echo "    VNet        : $VNET_NAME"
echo "    PE subnet   : $PRIVATE_ENDPOINT_SUBNET_PREFIX"
echo "    Storage     : $STORAGE_ACCOUNT"

if az network vnet subnet show \
  --resource-group "$NODE_RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$PRIVATE_ENDPOINT_SUBNET_NAME" \
  --output none 2>/dev/null; then
  echo "    Subnet already exists; reusing $PRIVATE_ENDPOINT_SUBNET_NAME"
else
  az network vnet subnet create \
    --resource-group "$NODE_RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$PRIVATE_ENDPOINT_SUBNET_NAME" \
    --address-prefixes "$PRIVATE_ENDPOINT_SUBNET_PREFIX" \
    --private-endpoint-network-policies Disabled \
    --output none
fi

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name "storage-private-link-${SN}" \
  --template-file storage-private-link.bicep \
  --parameters \
      vnetId="$VNET_ID" \
      privateEndpointSubnetId="$PRIVATE_ENDPOINT_SUBNET_ID" \
      storageAccountName="$STORAGE_ACCOUNT" \
  --output table

echo "==> Blob Private Link deployed. Storage clients in the AKS VNet now resolve the Blob endpoint to the Private Endpoint IP."