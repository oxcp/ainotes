#!/usr/bin/env bash
# Optional post-AKS deployment for private Blob connectivity.
# Usage: ./deploy-storage-private-link.sh
# Optional override: VNET_NAME=<aks-vnet-name> ./deploy-storage-private-link.sh

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"

ip_to_int() {
  local ip="$1"
  local a b c d
  IFS='.' read -r a b c d <<<"$ip"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
  local n="$1"
  echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

cidr_to_range() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local prefix="${cidr#*/}"
  local ip_int mask start end
  ip_int=$(ip_to_int "$ip")
  if [ "$prefix" -eq 0 ]; then
    start=0
    end=4294967295
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    start=$(( ip_int & mask ))
    end=$(( start | (0xFFFFFFFF ^ mask) ))
  fi
  echo "$start $end"
}

ceil_to_256() {
  local n="$1"
  echo $(( ((n + 255) / 256) * 256 ))
}

find_free_24() {
  local vnet_prefixes="$1"
  local used_prefixes="$2"
  local vprefix uprefix vstart vend cstart cstart_aligned cend c range ustart uend overlap

  while IFS= read -r vprefix; do
    [ -z "$vprefix" ] && continue
    [[ ! "$vprefix" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && continue

    local vp_len="${vprefix#*/}"
    [ "$vp_len" -gt 24 ] && continue

    range=$(cidr_to_range "$vprefix")
    vstart="${range%% *}"
    vend="${range##* }"
    cstart_aligned=$(ceil_to_256 "$vstart")

    for ((c = cstart_aligned; c + 255 <= vend; c += 256)); do
      cend=$((c + 255))
      overlap=0

      while IFS= read -r uprefix; do
        [ -z "$uprefix" ] && continue
        [[ ! "$uprefix" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && continue
        range=$(cidr_to_range "$uprefix")
        ustart="${range%% *}"
        uend="${range##* }"
        if ! { [ "$cend" -lt "$ustart" ] || [ "$uend" -lt "$c" ]; }; then
          overlap=1
          break
        fi
      done <<<"$used_prefixes"

      if [ "$overlap" -eq 0 ]; then
        echo "$(int_to_ip "$c")/24"
        return 0
      fi
    done
  done <<<"$vnet_prefixes"

  return 1
}

SN=$(az group show --resource-group "$RESOURCE_GROUP" --query "tags.deploymentSN" --output tsv 2>/dev/null | tr -d "\r\n" || echo "")
if [ -z "$SN" ]; then
  echo "ERROR: deploymentSN tag not found on $RESOURCE_GROUP. Deploy Module 1 first."
  exit 1
fi

AKS_NAME="${AKS_NAME:-aks-agenthost-${SN}}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stcagenthost${SN}}"
NODE_RESOURCE_GROUP=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --query nodeResourceGroup --output tsv | tr -d "\r\n")
AKS_SUBNET_ID=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_NAME" --query "agentPoolProfiles[0].vnetSubnetId" --output tsv | tr -d "\r\n")
VNET_NAME="${VNET_NAME:-}"
PRIVATE_ENDPOINT_SUBNET_NAME="${PRIVATE_ENDPOINT_SUBNET_NAME:-snet-private-endpoints}"

if [ -n "$VNET_NAME" ]; then
  echo "    Using VNET_NAME: $VNET_NAME"
elif [ -n "$AKS_SUBNET_ID" ] && [ "$AKS_SUBNET_ID" != "null" ]; then
  VNET_NAME=$(printf '%s' "$AKS_SUBNET_ID" | awk -F/ '{for (i=1; i<=NF; i++) if ($i == "virtualNetworks") {print $(i+1); exit}}')
else
  echo "    AKS vnetSubnetId is null (expected for AKS-managed VNet). Discovering VNet in node resource group..."
  VNET_NAME=$(az network vnet list --resource-group "$NODE_RESOURCE_GROUP" --query "[0].name" --output tsv | tr -d "\r\n")
  if [ -z "$VNET_NAME" ]; then
    echo "ERROR: No VNet found in $NODE_RESOURCE_GROUP."
    exit 1
  fi

  echo "    No VNET_NAME input provided."
  echo "    First VNet in $NODE_RESOURCE_GROUP: $VNET_NAME"
  read -r -p "Continue with this VNet? [y/N]: " CONFIRM
  case "$CONFIRM" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Aborted. Re-run with VNET_NAME=<your-vnet-name>."
      exit 1
      ;;
  esac
fi

VNET_ID=$(az network vnet show --resource-group "$NODE_RESOURCE_GROUP" --name "$VNET_NAME" --query id --output tsv | tr -d "\r\n")
VNET_PREFIXES=$(az network vnet show --resource-group "$NODE_RESOURCE_GROUP" --name "$VNET_NAME" --query "addressSpace.addressPrefixes[]" --output tsv | tr -d "\r")
SUBNET_PREFIXES_SINGLE=$(az network vnet subnet list --resource-group "$NODE_RESOURCE_GROUP" --vnet-name "$VNET_NAME" --query "[].addressPrefix" --output tsv | tr -d "\r")
SUBNET_PREFIXES_MULTI=$(az network vnet subnet list --resource-group "$NODE_RESOURCE_GROUP" --vnet-name "$VNET_NAME" --query "[].addressPrefixes[]" --output tsv | tr -d "\r")
USED_SUBNET_PREFIXES=$(printf '%s\n%s\n' "$SUBNET_PREFIXES_SINGLE" "$SUBNET_PREFIXES_MULTI" | awk 'NF')

AUTO_SUBNET_PREFIX=$(find_free_24 "$VNET_PREFIXES" "$USED_SUBNET_PREFIXES") || {
  echo "ERROR: Could not find a free /24 subnet inside VNet $VNET_NAME."
  echo "Set VNET_NAME to another VNet or manually create a dedicated subnet and rerun."
  exit 1
}
echo "    Auto-selected subnet prefix for $PRIVATE_ENDPOINT_SUBNET_NAME: $AUTO_SUBNET_PREFIX"

PRIVATE_ENDPOINT_SUBNET_ID="${VNET_ID}/subnets/${PRIVATE_ENDPOINT_SUBNET_NAME}"

echo "==> Deploying Blob Private Link"
echo "    Workshop RG : $RESOURCE_GROUP"
echo "    Node RG     : $NODE_RESOURCE_GROUP"
echo "    VNet        : $VNET_NAME"
echo "    PE subnet   : $PRIVATE_ENDPOINT_SUBNET_NAME ($AUTO_SUBNET_PREFIX)"
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
    --address-prefixes "$AUTO_SUBNET_PREFIX" \
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