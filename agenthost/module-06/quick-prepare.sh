#!/usr/bin/env bash
# prepare.sh -- Prepare shared infrastructure for Module 6.
#
#   1. Run Module-01 setup.sh
#   2. Run Module-03 prepare-agent-sandbox.sh, then deploy-storage-private-link.sh
#   3. Run Module-04 sandbox-deploy.sh (creates the SandboxGroup, not its guests)
#   4. Create aca-subnet in the AKS VNet and connect the SandboxGroup with ACA CLI
#
# Usage: ACA_SUBNET_PREFIX=<free IPv4 /24> bash prepare.sh
#        bash prepare.sh --skip-network
# Env overrides: RESOURCE_GROUP, LOCATION, DEPLOYMENT_SN, SUBSCRIPTION_ID,
#                VNET_NAME, ACA_SUBNET_PREFIX, CUSTOMER_VNET_CONNECTION_NAME.
# Existing Module-01/03/04 environment overrides also pass through unchanged.
# Prerequisites: Azure login, az/Bicep, kubectl, jq, openssl, sed; aca for step 4.
# Creates billable resources and updates kubeconfig; failures stop later steps.

set +x
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workshop="$(cd -- "$root/.." && pwd)"
fail() {
  printf 'ERROR [prepare]: %s\n' "$*" >&2
  exit 1
}

# -- Options and environment defaults ----------------------------------------
network=true
case "${1:-}" in
  "") ;;
  --skip-network) network=false ;;
  --help)
    printf '%s\n' \
      'Usage: ACA_SUBNET_PREFIX=<free IPv4 /24> bash prepare.sh [--skip-network]' \
      'Runs Module-01 setup, Module-03 preparation + Blob Private Link, and Module-04 SandboxGroup deployment.' \
      'Step 4 uses a dedicated aca-subnet; choose a free /24 inside the AKS VNet.' \
      '--skip-network skips only step 4; Blob Private Link is still deployed in step 2.' \
      'This provisions billable resources. Existing scripts can prompt and update kubeconfig.' \
      'No automatic rollback, guest creation or Module-06 application deployment.'
    exit 0
    ;;
  *) fail "Unknown option: $1 (use --help)" ;;
esac
(($# <= 1)) || fail "Only --skip-network or --help is supported"

export RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
export LOCATION="${LOCATION:-westus3}"
prefix="${ACA_SUBNET_PREFIX:-}"
connection="${CUSTOMER_VNET_CONNECTION_NAME:-module06-aks-vnet}"
[[ "$RESOURCE_GROUP" =~ ^[A-Za-z0-9_.()-]+$ && "$RESOURCE_GROUP" != *. ]] || fail "Invalid RESOURCE_GROUP"
for tool in az jq kubectl openssl sed; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
if $network; then
  [[ "$prefix" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ ]] ||
    fail "Set ACA_SUBNET_PREFIX to a free IPv4 /24 in the AKS VNet, or use --skip-network"
  jq -en --arg prefix "$prefix" '$prefix|split("/")[0]|split(".")|map(tonumber)|
    all(.[]; .<=255) and .[3]==0' >/dev/null || fail "ACA_SUBNET_PREFIX must be an aligned IPv4 /24"
  [[ "$connection" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,31}$ ]] || fail "Invalid CUSTOMER_VNET_CONNECTION_NAME"
  command -v aca >/dev/null || fail "Required tool missing: aca"
  help="$(aca sandboxgroup network create --help)" || fail "Cannot check ACA networking capabilities"
  [[ "$help" == *--vnet-subnet-id* ]] || fail "Upgrade aca: SandboxGroup VNet connections are required"
fi
for script in module-01/setup.sh module-03/prepare-agent-sandbox.sh \
  module-03/deploy-storage-private-link.sh module-04/sandbox-deploy.sh; do
  bash -n "$workshop/$script" || fail "Invalid prerequisite script: $script"
done

# -- Keep all child scripts in the same Azure subscription and deployment -----
if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi
subscription="$(az account show --query id -o tsv | tr -d '\r\n')" || fail "Azure login required"
[[ -n "$subscription" && "$subscription" != null ]] || fail "Active subscription missing"
groups="$(az group list -o json)" || fail "Cannot discover existing workshop group"
existing_sn="$(jq -er --arg rg "$RESOURCE_GROUP" '
  [.[]|select((.name|ascii_downcase)==($rg|ascii_downcase))] |
  if length==0 then "" elif length==1 then
    .[0].tags.deploymentSN | strings | select(test("^[a-z0-9]{6}$"))
  else error("Ambiguous resource group") end' <<<"$groups" | tr -d '\r\n')" ||
  fail "Existing resource group must have a valid six-character deploymentSN tag"
export DEPLOYMENT_SN="${DEPLOYMENT_SN:-${existing_sn:-$(openssl rand -hex 3)}}"
[[ "$DEPLOYMENT_SN" =~ ^[a-z0-9]{6}$ ]] || fail "DEPLOYMENT_SN must have six lowercase letters/digits"
[[ -z "$existing_sn" || "$DEPLOYMENT_SN" == "$existing_sn" ]] ||
  fail "DEPLOYMENT_SN conflicts with the existing resource group"

run_stage() {
  local directory="$1" script="$2"
  (cd -- "$workshop/$directory" && bash "$script") ||
    fail "$directory/$script failed; no later stages ran. No automatic rollback."
}

# -- Run prerequisite modules from their own directories ----------------------
echo "==> [1/4] Deploying Module-01 shared infrastructure"
run_stage module-01 setup.sh
echo "==> [2/4] Preparing Module-03 AKS and Blob Private Link"
run_stage module-03 prepare-agent-sandbox.sh
run_stage module-03 deploy-storage-private-link.sh
echo "==> [3/4] Deploying the Module-04 SandboxGroup"
run_stage module-04 sandbox-deploy.sh
if ! $network; then
  echo "==> [4/4] Skipped ACA VNet connection; complete Module-04 private networking before deploy.sh"
  exit 0
fi

# -- Resolve the AKS-managed VNet; refuse ambiguous discovery ------------------
echo "==> [4/4] Connecting the SandboxGroup to aca-subnet in the AKS VNet"
aks="aks-agenthost-$DEPLOYMENT_SN"
group="sandbox-group-agenthost-$DEPLOYMENT_SN"
node_group="$(az aks show -g "$RESOURCE_GROUP" -n "$aks" --query nodeResourceGroup -o tsv | tr -d '\r\n')" ||
  fail "Cannot resolve AKS node resource group"
vnets="$(az network vnet list -g "$node_group" -o json)" || fail "Cannot read AKS VNets"
vnet="$(jq -er --arg name "${VNET_NAME:-}" '
  if $name=="" then . else map(select(.name==$name)) end |
  if length==1 then .[0] else error("Select exactly one VNet using VNET_NAME") end
  ' <<<"$vnets")" || fail "AKS VNet discovery is ambiguous; set VNET_NAME"
vnet_id="$(jq -er '.id' <<<"$vnet" | tr -d '\r\n')"
vnet_name="$(jq -er '.name' <<<"$vnet" | tr -d '\r\n')"
[[ "$(jq -r '.location|ascii_downcase' <<<"$vnet" | tr -d '\r\n')" == "${LOCATION,,}" ]] ||
  fail "AKS VNet and SandboxGroup must be in the same region"
subnet_id="$vnet_id/subnets/aca-subnet"

aca_call() {
  aca "$@" --subscription "$subscription" --resource-group "$RESOURCE_GROUP" --region "$LOCATION" -o json
}
read_connection() {
  local state
  state="$(aca_call sandboxgroup get --name "$group")" || fail "Cannot read SandboxGroup connections"
  jq -c --arg name "$connection" '
    if (.vnetConnections|type)!="array" then error("Missing VNet connection inventory") else
      [.vnetConnections[]|select((.name|ascii_downcase)==($name|ascii_downcase))] |
      if length<=1 then .[0] // null else error("Ambiguous connection") end end
    ' <<<"$state" || fail "Invalid SandboxGroup connection inventory"
}
current="$(read_connection)"
if [[ "$current" != null ]]; then
  jq -e --arg id "$subnet_id" '(.properties.subnetId|ascii_downcase)==($id|ascii_downcase)' \
    <<<"$current" >/dev/null || fail "Existing connection targets another subnet; refusing to repoint it"
fi

# -- Create a dedicated delegated subnet, or verify the existing one ----------
subnets="$(az network vnet subnet list -g "$node_group" --vnet-name "$vnet_name" -o json)" ||
  fail "Cannot read VNet subnets"
subnet="$(jq -c '[.[]|select(.name=="aca-subnet")] |
  if length<=1 then .[0] // null else error("Ambiguous subnet") end' <<<"$subnets")" ||
  fail "Invalid subnet inventory"
if [[ "$subnet" == null ]]; then
  az network vnet subnet create \
    --resource-group "$node_group" \
    --vnet-name "$vnet_name" \
    --name aca-subnet \
    --address-prefixes "$prefix" \
    --delegations Microsoft.App/environments \
    -o none || fail "Subnet creation failed; choose a free /24 inside the AKS VNet"
else
  jq -e --arg prefix "$prefix" '
    (.addressPrefix // .addressPrefixes[0])==$prefix and
    (.addressPrefixes // [$prefix]|length)==1 and
    (.delegations|length)==1 and .delegations[0].serviceName=="Microsoft.App/environments"
    ' <<<"$subnet" >/dev/null ||
    fail "Existing aca-subnet prefix/delegation differs; review it manually instead of overwriting"
fi

# -- Create the connection and wait for persisted readiness -------------------
if [[ "$current" == null ]]; then
  aca_call sandboxgroup network create \
    --group "$group" \
    --name "$connection" \
    --vnet-subnet-id "$subnet_id" >/dev/null || fail "ACA VNet connection creation failed"
fi
for attempt in {1..60}; do
  current="$(read_connection)"
  if jq -e --arg id "$subnet_id" '
    (.properties.subnetId|ascii_downcase)==($id|ascii_downcase) and
    .properties.provisioningState=="Succeeded"' <<<"$current" >/dev/null; then
    printf 'Preparation complete. Connection: %s\nNext: bash deploy.sh --migrate\n' "$connection"
    printf 'If the group has multiple connections, export CUSTOMER_VNET_CONNECTION_NAME=%s before deploy.sh.\n' "$connection"
    exit 0
  fi
  state="$(jq -r '.properties.provisioningState // "NotVisible"' <<<"$current" | tr -d '\r\n')"
  case "$state" in
    Failed | Canceled | Deleting) fail "ACA VNet connection is $state; inspect networking before retrying" ;;
  esac
  if ((attempt < 60)); then
    sleep 10
  fi
done
fail "ACA VNet connection was not Succeeded after bounded polling; resources retained for inspection"
