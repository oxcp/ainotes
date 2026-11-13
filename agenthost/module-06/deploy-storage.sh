#!/usr/bin/env bash
# deploy-storage.sh -- Module 6: create data in the existing Module 1 storage account.
#
#   1. Validate arguments and shared Blob configuration
#   2. Resolve and verify the existing account
#   3. Create only the private data container (unless resolving its ID)
#
# Usage: bash deploy-storage.sh [--resolve]
# Env overrides: STORAGE_ACCOUNT_NAME, ACA_COMMON and others in --help.
# Prerequisites: Module 1 deployed; az and jq installed.

set +x
set -euo pipefail

# -- Helpers and command-line options ----------------------------------------
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() {
  printf 'Error [storage]: %s\n' "$*" >&2
  exit 1
}
usage() {
  cat <<'HELP'
Usage: bash deploy-storage.sh [--resolve|--discover]
By default, incrementally provision private data in an EXISTING account using storage.bicep.
--resolve prints only the derived data container ARM ID (used by deploy.sh).
--discover ignores saved common/Agent configuration and prints current storage metadata as JSON.
Resolution is read-only: no files or Azure writes.
Never deploys the account/blob service, changes networking/versioning/RBAC, or deletes data.
Inputs: ACA_COMMON / ACA_CONFIG (Blob URLs must agree), KB_STORAGE_CONTAINER_ID (optional),
STORAGE_ACCOUNT_NAME, STORAGE_SUBSCRIPTION_ID, STORAGE_RESOURCE_GROUP.
Scope defaults: SUBSCRIPTION_ID/current account, RESOURCE_GROUP/rg-agenthost-workshop.
Account fallback: stcagenthost<DEPLOYMENT_SN or RG tags.deploymentSN>.
Explicit relative JSON paths are relative to the caller's directory.
HELP
}
# -- Validate inputs and shared Blob configuration ---------------------------
mode=provisioned
if (($#)); then
  [[ $# == 1 ]] || fail "Specify at most one option (use --help)"
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --resolve)
      mode=resolve
      ;;
    --discover)
      mode=discover
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
fi
for tool in jq az; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
echo "==> [1/3] Validating shared Blob configuration" >&2

urls=()
# Accept either common settings or the generated five-role map, but require one shared account.
for file in "${ACA_COMMON:-$root/.local/aca-common.json}" "${ACA_CONFIG:-$root/.local/aca-config.json}"; do
  [[ "$mode" != discover ]] || break
  [[ -e "$file" || -L "$file" ]] || continue
  [[ -f "$file" && ! -L "$file" ]] || fail "Configuration must be a regular file, not a symbolic link"
  settings="$(jq -ce '
      if has("chat") then [.[]] else [.] end |
      if all(.[]; .AZURE_STORAGE_CONTAINER=="data" and
        (.AZURE_STORAGE_ACCOUNT_URL | type=="string" and test("^https://[^/?#]+/?$")))
      then map(.AZURE_STORAGE_ACCOUNT_URL | rtrimstr("/")) | unique
      else error("Expected data container and HTTPS account URLs") end
    ' "$file")" || fail "Invalid Blob configuration in $file"
  while IFS= read -r url; do
    urls+=("$url")
  done < <(jq -r '.[]' <<<"$settings" | tr -d '\r')
done
url="${urls[0]:-}"
for candidate in "${urls[@]}"; do
  [[ "${candidate,,}" == "${url,,}" ]] || fail "ACA_COMMON and ACA_CONFIG Blob account URLs differ"
done

# -- Resolve the existing Module 1 storage account ----------------------------
echo "==> [2/3] Resolving and verifying the existing storage account" >&2
container="${KB_STORAGE_CONTAINER_ID:-}"
name="${STORAGE_ACCOUNT_NAME:-}"
subscription="${STORAGE_SUBSCRIPTION_ID:-${SUBSCRIPTION_ID:-}}"
resource_group="${STORAGE_RESOURCE_GROUP:-${RESOURCE_GROUP:-rg-agenthost-workshop}}"
for key in container name subscription resource_group; do
  printf -v "$key" '%s' "$(printf '%s' "${!key}" | tr -d '\r\n')"
done
if [[ -n "$container" ]]; then
  # A full container ID selects its own scope; reject conflicting explicit storage overrides.
  [[ "$container" =~ ^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([a-z0-9]{3,24})/blobServices/default/containers/data$ ]] \
    || fail "KB_STORAGE_CONTAINER_ID must be a Microsoft.Storage data container ARM ID"
  id_sub="${BASH_REMATCH[1]}"
  id_rg="${BASH_REMATCH[2]}"
  id_name="${BASH_REMATCH[3]}"
  [[ -z "$name" || "$name" == "$id_name" ]] || fail "STORAGE_ACCOUNT_NAME conflicts with KB_STORAGE_CONTAINER_ID"
  [[ -z "${STORAGE_SUBSCRIPTION_ID:-}" || "${subscription,,}" == "${id_sub,,}" ]] \
    || fail "STORAGE_SUBSCRIPTION_ID conflicts with KB_STORAGE_CONTAINER_ID"
  [[ -z "${STORAGE_RESOURCE_GROUP:-}" || "${resource_group,,}" == "${id_rg,,}" ]] \
    || fail "STORAGE_RESOURCE_GROUP conflicts with KB_STORAGE_CONTAINER_ID"
  subscription="$id_sub"
  resource_group="$id_rg"
  name="$id_name"
fi
subscription="${subscription:-$(az account show --query id -o tsv | tr -d '\r\n')}"
[[ -n "$subscription" && "$subscription" != null ]] || fail "Azure subscription not found"
if [[ "$url" =~ ^https://([a-z0-9]{3,24})\.blob\.[a-zA-Z0-9.-]+$ ]]; then
  url_name="${BASH_REMATCH[1]}"
  [[ -z "$name" || "$name" == "$url_name" ]] || fail "Storage account conflicts with configured Blob URL"
  name="$url_name"
fi
if [[ -z "$name" ]]; then
  sn="${DEPLOYMENT_SN:-}"
  sn="$(printf '%s' "$sn" | tr -d '\r\n')"
  if [[ -z "$sn" ]]; then
    sn="$(az group show --subscription "$subscription" -n "$resource_group" --query tags.deploymentSN -o tsv | tr -d '\r\n')" \
      || fail "Cannot read existing Module-01 resource group"
  fi
  [[ "$sn" =~ ^[a-z0-9]+$ ]] || fail "Set STORAGE_ACCOUNT_NAME or a valid DEPLOYMENT_SN / RG deploymentSN tag"
  name="stcagenthost$sn"
fi
[[ "$name" =~ ^[a-z0-9]{3,24}$ ]] || fail "Invalid storage account name"
account_id="/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.Storage/storageAccounts/$name"
# ARM reads work independently of Blob endpoint network access. This does not test SDK connectivity.
account="$(az resource show --ids "$account_id" --api-version 2023-01-01 -o json)" \
  || fail "Existing Module-01 storage account not found or inaccessible: $account_id"
actual_id="$(jq -er '.id | strings | select(length>0)' <<<"$account" | tr -d '\r\n')" \
  || fail "Existing storage account ARM response has no ID"
[[ "${actual_id,,}" == "${account_id,,}" ]] || fail "Resolved storage account ID differs from requested account"
endpoint="$(jq -er '.properties.primaryEndpoints.blob | strings | select(length>0) | rtrimstr("/")' <<<"$account" | tr -d '\r\n')" \
  || fail "Existing storage account has no Blob endpoint"
[[ -z "$url" || "${endpoint,,}" == "${url,,}" ]] || fail "Storage account does not match configured AZURE_STORAGE_ACCOUNT_URL"
container="$actual_id/blobServices/default/containers/data"
if [[ "$mode" == resolve ]]; then
  # Keep stdout machine-readable: deploy.sh captures this exact ARM ID via command substitution.
  printf '%s\n' "$container"
  exit 0
fi
if [[ "$mode" == discover ]]; then
  jq -n --arg id "$container" --arg url "$endpoint" \
    '{KB_STORAGE_CONTAINER_ID:$id,AZURE_STORAGE_ACCOUNT_URL:$url,AZURE_STORAGE_CONTAINER:"data"}'
  exit 0
fi
# -- Provision only the container; leave shared account settings unchanged ----
echo "==> [3/3] Provisioning the private data container (shared account unchanged)" >&2
# Persist the exact Module-06 child before ARM so storage-only/failed deployments
# can be cleaned without deriving a storage account name during deletion.
inventory="$root/.local/storage-deployment.json"
[[ ! -L "$root/.local" && ! -L "$inventory" ]] || fail "Storage inventory must not be a symbolic link"
mkdir -p "$root/.local"
if [[ -e "$inventory" ]]; then
  jq -e --arg id "$container" '.kind=="module06-storage" and .module=="module-06" and .container_id==$id' \
    "$inventory" >/dev/null || fail "Storage inventory selects another target; preserve and review it first"
fi
jq -n --arg id "$container" '{kind:"module06-storage",module:"module-06",container_id:$id}' >"$inventory"
# Incremental mode leaves unrelated resources intact; existing account settings are not deployed.
az deployment group create \
  --subscription "$subscription" \
  --resource-group "$resource_group" \
  --name module06-storage \
  --mode Incremental \
  --template-file "$root/bicep/storage.bicep" \
  --parameters "storageAccountName=$name" --only-show-errors -o none \
  || fail "Incremental data container provisioning failed; no later stages should run"
jq -n --arg status "$mode" --arg id "$container" --arg url "$endpoint" \
  '{status:$status,KB_STORAGE_CONTAINER_ID:$id,AZURE_STORAGE_ACCOUNT_URL:$url,AZURE_STORAGE_CONTAINER:"data"}'
