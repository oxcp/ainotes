#!/usr/bin/env bash

set -euo pipefail

# All values can be overridden with environment variables.
CLUSTER_NAME="${CLUSTER_NAME:-aksbyocni}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-aks-byocni}"
LOCATION="${LOCATION:-southeastasia}"
NODE_COUNT="${NODE_COUNT:-3}"
MAX_PODS="${MAX_PODS:-50}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D2ads_v5}"
SERVICE_CIDR="${SERVICE_CIDR:-172.168.0.0/16}"
DNS_SERVICE_IP="${DNS_SERVICE_IP:-172.168.0.10}"
POD_CIDR="${POD_CIDR:-10.30.0.0/16}"

# Optional values. Leave them empty to use the active Azure subscription,
# the AKS default Kubernetes version, and no attached ACR.
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"
ACR_ID="${ACR_ID:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command '$1' was not found." >&2
    exit 1
  fi
}

require_command az

if ! az account show --output none 2>/dev/null; then
  echo "ERROR: Azure CLI is not logged in. Run 'az login' first." >&2
  exit 1
fi

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  echo "==> Selecting Azure subscription: $SUBSCRIPTION_ID"
  az account set --subscription "$SUBSCRIPTION_ID"
fi

ACTIVE_SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

echo "==> Configuration"
echo "    Subscription : $ACTIVE_SUBSCRIPTION_ID"
echo "    Resource group: $RESOURCE_GROUP"
echo "    Location      : $LOCATION"
echo "    AKS cluster   : $CLUSTER_NAME"
echo "    Pod CIDR      : $POD_CIDR"
echo "    Service CIDR  : $SERVICE_CIDR"

echo "==> Creating or updating resource group"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

if az aks show \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --output none 2>/dev/null; then
  NETWORK_PLUGIN="$(az aks show \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query networkProfile.networkPlugin \
    --output tsv)"

  if [[ "$NETWORK_PLUGIN" != "none" ]]; then
    echo "ERROR: Existing cluster uses network plugin '$NETWORK_PLUGIN', not 'none'." >&2
    exit 1
  fi

  echo "==> AKS cluster already exists with network plugin 'none'; reusing it"
else
  echo "==> Creating AKS cluster without a preinstalled CNI"

  aks_create_args=(
    --name "$CLUSTER_NAME"
    --resource-group "$RESOURCE_GROUP"
    --location "$LOCATION"
    --network-plugin none
    --pod-cidr "$POD_CIDR"
    --service-cidr "$SERVICE_CIDR"
    --dns-service-ip "$DNS_SERVICE_IP"
    --max-pods "$MAX_PODS"
    --node-count "$NODE_COUNT"
    --node-vm-size "$NODE_VM_SIZE"
    --vm-set-type VirtualMachineScaleSets
    --load-balancer-sku standard
    --ssh-access disabled
  )

  if [[ -n "$KUBERNETES_VERSION" ]]; then
    aks_create_args+=(--kubernetes-version "$KUBERNETES_VERSION")
  fi

  if [[ -n "$ACR_ID" ]]; then
    aks_create_args+=(--attach-acr "$ACR_ID")
  fi

  az aks create "${aks_create_args[@]}" --output none
fi

echo "==> Downloading cluster credentials"
az aks get-credentials \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --overwrite-existing

echo
echo "AKS BYO CNI cluster is ready for Cilium installation."
echo "The nodes can remain NotReady until a CNI plugin is installed."
echo "Continue with README.md."
