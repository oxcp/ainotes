#!/usr/bin/env bash
# cleanup.sh — Release Module 1–4 workshop resources.
#
# Run Module-06 cleanup first. Discovery completes before any deletion.
# Usage: bash cleanup.sh             (preview only)
#        bash cleanup.sh --execute   (requires confirmation)
# Env overrides: RESOURCE_GROUP, SUBSCRIPTION_ID, DEPLOYMENT_SN,
#                AKS_NAME, DEPLOYMENT_NAME
# Prerequisites: Azure CLI login, jq, aca when SandboxGroups exist,
#                and permission to delete the resources.

set +x
set -Eeuo pipefail

# ── Shell compatibility and error reporting ─────────────────────────────────
case "${OSTYPE:-}" in
  msys*|cygwin*)
    export MSYS2_ARG_CONV_EXCL="/subscriptions/;${MSYS2_ARG_CONV_EXCL:-}"
    ;;
esac

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

trap 'rc=$?; printf "Cleanup stopped (%s). Review the error before retrying.\n" "$rc" >&2; exit "$rc"' ERR

# ── Command-line options ────────────────────────────────────────────────────
execute=false
case "${1:-}" in
  "") ;;
  --execute)
    execute=true
    ;;
  --help)
    printf '%s\n' 'Usage: bash cleanup.sh [--execute]' \
      'Default: discovery and dry-run only. --execute requires typing "delete <resource-group>".' \
      'Run Module-06 cleanup first. This script deletes the entire selected resource group.' \
      'Environment: RESOURCE_GROUP (default rg-agenthost-workshop), AKS_NAME, DEPLOYMENT_NAME,' \
      'DEPLOYMENT_SN (must match the resource-group tag), SUBSCRIPTION_ID (default active subscription).'
    exit 0 ;;
  *)
    fail "Unknown option: $1"
    ;;
esac
(($# <= 1)) || fail "Only --execute or --help is supported"

for tool in az jq; do
  if ! command -v "$tool" >/dev/null; then
    fail "Required tool missing: $tool"
  fi
done

jq() {
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      command jq --binary "$@"
      ;;
    *)
      command jq "$@"
      ;;
  esac
}

# ── Resolve subscription and workshop resource names ────────────────────────
resource_group="${RESOURCE_GROUP:-rg-agenthost-workshop}"
[[ "$resource_group" =~ ^[A-Za-z0-9_.()-]+$ && "$resource_group" != *. ]] ||
  fail "Invalid RESOURCE_GROUP"

echo "==> Discovering workshop resources (no deletion)"
account_args=()
if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
  account_args=(--subscription "$SUBSCRIPTION_ID")
fi
account="$(az account show "${account_args[@]}" -o json)" || fail "Cannot read Azure account"
subscription="$(jq -er '.id | select(type=="string" and test("^[0-9a-fA-F-]{36}$"))' <<<"$account")" ||
  fail "Invalid subscription ID"

az_call() {
  az "$@" --subscription "$subscription" --only-show-errors
}

groups="$(az_call group list -o json)" || fail "Cannot list resource groups"
group="$(jq -ce --arg rg "$resource_group" '
  [ .[] | select((.name|ascii_downcase)==($rg|ascii_downcase)) ] |
  if length<=1 then . else error("Duplicate resource group") end' <<<"$groups")" ||
  fail "Invalid resource-group inventory"
if [[ "$group" == '[]' ]]; then
  printf '%s is already absent in subscription %s; nothing to delete.\n' "$resource_group" "$subscription"
  exit 0
fi

tag_sn="$(jq -er '.[0].tags.deploymentSN |
  select(type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"))' <<<"$group")" ||
  fail "Missing or invalid deploymentSN tag; no resources deleted"
sn="${DEPLOYMENT_SN:-$tag_sn}"
[[ "$sn" == "$tag_sn" ]] || fail "DEPLOYMENT_SN does not match the resource-group tag; nothing deleted"
deployment_name="${DEPLOYMENT_NAME:-main-${sn}}"
aks_name="${AKS_NAME:-aks-agenthost-${sn}}"
[[ "$deployment_name" =~ ^[A-Za-z0-9_.()-]{1,64}$ ]] || fail "Invalid DEPLOYMENT_NAME"
[[ "$aks_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail "Invalid AKS_NAME"
rg_id="/subscriptions/$subscription/resourceGroups/$resource_group"

# ── Discover all ACA SandboxGroups in the selected workshop group ───────────
sandbox_groups="$(az_call resource list \
  --resource-group "$resource_group" \
  --resource-type Microsoft.App/sandboxGroups \
  -o json)" || fail "Cannot list ACA SandboxGroups"
sandbox_groups="$(jq -ce --arg prefix "${rg_id,,}/providers/microsoft.app/sandboxgroups/" '
  if type=="array" and all(.[];
    (.name | type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) and
    (.location | type=="string" and test("^[A-Za-z0-9-]+$")) and
    ((.id|ascii_downcase)==($prefix+(.name|ascii_downcase)))) and
    ([.[].name|ascii_downcase]|length==(unique|length))
  then . else error("Invalid or out-of-scope SandboxGroup") end' <<<"$sandbox_groups")" ||
  fail "Invalid ACA SandboxGroup inventory; no resources deleted"
if [[ "$sandbox_groups" != '[]' ]]; then
  command -v aca >/dev/null || fail "Required tool missing: aca"
fi

# ── Discover the AKS VNet before deleting AKS ────────────────────────────────
clusters="$(az_call aks list --resource-group "$resource_group" -o json)" || fail "Cannot list AKS"
cluster="$(jq -ce --arg name "$aks_name" '
  [ .[] | select(.name==$name) ] |
  if length<=1 then . else error("Duplicate AKS") end' <<<"$clusters")" || fail "Invalid AKS inventory"
vnets='[]'
if [[ "$cluster" != '[]' ]]; then
  vnets="$(jq -ce '[.[0].agentPoolProfiles[].vnetSubnetId |
    select(type=="string") | sub("/subnets/[^/]+$";"";"i")] | unique' <<<"$cluster")" ||
    fail "Cannot resolve AKS subnet IDs"
  if [[ "$vnets" == '[]' ]]; then
    node_group="$(jq -er '.[0].nodeResourceGroup | select(type=="string" and length>0)' <<<"$cluster")" ||
      fail "AKS has no node resource group"
    node_vnets="$(az_call network vnet list --resource-group "$node_group" -o json)" ||
      fail "Cannot discover AKS-managed VNet"
    vnets="$(jq -ce 'if length==1 then [.[0].id] else error("Expected one AKS-managed VNet") end' <<<"$node_vnets")" ||
      fail "AKS VNet is missing or ambiguous; no resources deleted"
  fi
fi

# ── Select only workshop network resources in the AKS VNet ──────────────────
endpoints="$(az_call network private-endpoint list --resource-group "$resource_group" -o json)" ||
  fail "Cannot list private endpoints"
nics="$(az_call network nic list --resource-group "$resource_group" -o json)" || fail "Cannot list NICs"
selected_endpoints="$(jq -ce --argjson vnets "$vnets" '
  def in_vnet($id): ($id // "" | ascii_downcase | sub("/subnets/[^/]+$";"";"i")) as $v |
    any($vnets[]; ascii_downcase==$v);
  [ .[] | select(in_vnet(.subnet.id)) ]' <<<"$endpoints")" || fail "Invalid private endpoint inventory"
selected_nics="$(jq -ce --argjson vnets "$vnets" --argjson endpoints "$selected_endpoints" '
  def in_vnet($id): ($id // "" | ascii_downcase | sub("/subnets/[^/]+$";"";"i")) as $v |
    any($vnets[]; ascii_downcase==$v);
  [ .[] | . as $nic | select(
    any(.ipConfigurations[]?; in_vnet(.subnet.id)) or
    any($endpoints[].networkInterfaces[]?; (.id|ascii_downcase)==($nic.id|ascii_downcase))) ] |
  if any(.[]; .virtualMachine.id? != null) then error("NIC is attached to a VM") else . end' <<<"$nics")" ||
  fail "Invalid NIC inventory or selected NIC is attached to a VM; review manually"
for inventory in "$selected_endpoints" "$selected_nics"; do
  jq -e --arg prefix "${rg_id,,}/providers/microsoft.network/" '
    all(.[]; (.id|ascii_downcase|startswith($prefix)))' <<<"$inventory" >/dev/null ||
    fail "Network resource outside the workshop resource group"
done

# ── Save deployment records before deleting their resource group ────────────
deployments="$(az_call deployment group list --resource-group "$resource_group" -o json)" ||
  fail "Cannot list resource-group deployments"
sub_deployments="$(az_call deployment sub list -o json)" || fail "Cannot list subscription deployments"
has_sub_deployment="$(jq -r --arg name "$deployment_name" 'any(.[]; .name==$name)' <<<"$sub_deployments")" ||
  fail "Invalid subscription deployment inventory"
[[ "$has_sub_deployment" == true || "$has_sub_deployment" == false ]] || fail "Invalid subscription deployment inventory"

# ── Preview and explicit confirmation ───────────────────────────────────────
echo ""
echo "==> Cleanup plan"
echo "    Subscription    : $subscription"
echo "    Resource Group  : $resource_group"
echo "    Deployment SN   : $sn"
echo "    AKS             : $aks_name"
echo "    Deployment name : $deployment_name"
echo ""
printf '    [1/6] Delete ALL ACA SandboxGroups in the resource group:\n'
jq -r '.[].id' <<<"$sandbox_groups"
printf '    [2/6] Delete workshop private endpoints and NICs in the AKS VNet:\n'
jq -r '.[].id' <<<"$selected_endpoints"
jq -r '.[].id' <<<"$selected_nics"
printf '    [3/6] Delete AKS: %s (matching clusters: %s)\n' "$aks_name" "$(jq 'length' <<<"$cluster")"
printf '    [4/6] Delete resource-group deployment records:\n'
jq -r '.[].name' <<<"$deployments"
printf '    [5/6] Delete subscription deployment record: %s (exists: %s)\n' "$deployment_name" "$has_sub_deployment"
printf '    [6/6] Delete the ENTIRE resource group: %s\n' "$resource_group"
printf 'Back up valuable Sandbox state outside the group before deletion; group-local snapshots are not an external backup.\n'
printf 'AKS deletion also removes its managed node resource group. Deployment record deletion alone does not delete resources.\n'
if ! "$execute"; then
  printf 'Dry-run only. Run Module-06 cleanup first, then rerun with --execute.\n'
  exit 0
fi
printf 'All resources and data in this group will be deleted. Type "delete %s": ' "$resource_group"
IFS= read -r confirmation || fail "Confirmation required"
[[ "$confirmation" == "delete $resource_group" ]] || fail "Confirmation did not match; nothing deleted"

# ── Step 1: Delete ACA SandboxGroups before removing network dependencies ───
echo "==> [1/6] Deleting ACA SandboxGroups"
while IFS=$'\t' read -r name region; do
  echo "    SandboxGroup: $name ($region)"
  aca sandboxgroup delete \
    --name "$name" \
    --subscription "$subscription" \
    --resource-group "$resource_group" \
    --region "$region" \
    --yes || fail "ACA SandboxGroup deletion failed: $name; no later cleanup steps ran"
done < <(jq -r '.[] | [.name,.location] | @tsv' <<<"$sandbox_groups")
if [[ "$sandbox_groups" != '[]' ]]; then
  remaining_sandbox_groups="$(aca sandboxgroup list \
    --subscription "$subscription" \
    --resource-group "$resource_group" \
    -o json)" || fail "Cannot verify ACA SandboxGroup deletion; no later cleanup steps ran"
  jq -e --argjson selected "$sandbox_groups" '
    type=="array" and all(.[]; (.id|type=="string")) and
    all(.[]; .id as $id | all($selected[]; (.id|ascii_downcase)!=($id|ascii_downcase)))
    ' <<<"$remaining_sandbox_groups" >/dev/null ||
    fail "ACA SandboxGroups remain or verification response is invalid; no later cleanup steps ran"
fi

# ── Step 2: Delete Private Endpoints, then any remaining selected NICs ───────
echo "==> [2/6] Deleting Private Endpoints and network interfaces"
while IFS= read -r id; do
  if [[ -n "$id" ]]; then
    echo "    Private Endpoint: $id"
    az_call network private-endpoint delete --ids "$id"
  fi
done < <(jq -r '.[].id' <<<"$selected_endpoints")
# Azure normally removes a Private Endpoint's managed NIC automatically.
remaining_nics="$(az_call network nic list --resource-group "$resource_group" -o json)" ||
  fail "Cannot verify remaining NICs"
remaining_selected="$(jq -r --argjson selected "$selected_nics" '
  .[] | . as $nic | select(any($selected[]; (.id|ascii_downcase)==($nic.id|ascii_downcase))) | .id' <<<"$remaining_nics")" ||
  fail "Invalid remaining NIC inventory"
while IFS= read -r id; do
  if [[ -n "$id" ]]; then
    echo "    Network interface: $id"
    az_call network nic delete --ids "$id"
  fi
done <<<"$remaining_selected"

# ── Step 3: Delete AKS and wait for its managed resources to be removed ──────
echo "==> [3/6] Deleting AKS: $aks_name"
if [[ "$cluster" != '[]' ]]; then
  az_call aks delete \
    --resource-group "$resource_group" \
    --name "$aks_name" \
    --yes
else
  echo "    AKS is already absent; skipping."
fi

# ── Step 4: Delete resource-group deployment records ────────────────────────
echo "==> [4/6] Deleting resource-group deployment records"
while IFS= read -r name; do
  if [[ -n "$name" ]]; then
    echo "    Deployment: $name"
    az_call deployment group delete \
      --resource-group "$resource_group" \
      --name "$name"
  fi
done < <(jq -r '.[].name' <<<"$deployments")

# ── Step 5: Delete the subscription deployment using the saved suffix ───────
echo "==> [5/6] Deleting subscription deployment: $deployment_name"
if [[ "$has_sub_deployment" == true ]]; then
  az_call deployment sub delete --name "$deployment_name"
else
  echo "    Deployment record is already absent; skipping."
fi

# ── Step 6: Delete the resource group and verify completion ──────────────────
echo "==> [6/6] Deleting resource group: $resource_group"
az_call group delete --name "$resource_group" --yes
remaining_groups="$(az_call group list -o json)" || fail "Cannot verify resource-group deletion"
jq -e --arg rg "$resource_group" 'all(.[]; (.name|ascii_downcase)!=($rg|ascii_downcase))' <<<"$remaining_groups" >/dev/null ||
  fail "Resource group still exists; check Azure deletion status"
printf 'Cleanup complete: %s removed from subscription %s.\n' "$resource_group" "$subscription"
