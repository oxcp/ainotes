#!/usr/bin/env bash
# Add embeddings without recreating the existing Foundry account/project or changing Module-01 RBAC.
# Usage: bash deploy-models.sh
# Defaults follow Module-01 names; model version, SKU and capacity are explicit environment overrides.
set +x
set -euo pipefail
umask 077
case "${OSTYPE:-}" in
  msys*|cygwin*) export MSYS2_ARG_CONV_EXCL="/subscriptions/;/SUBSCRIPTIONS/;${MSYS2_ARG_CONV_EXCL:-}" ;;
esac
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail() { printf 'Error [models]: %s\n' "$*" >&2; exit 1; }
if [[ $# == 1 && "$1" == --help ]]; then
  printf '%s\n' 'Usage: bash deploy-models.sh' \
    'Deploys embeddings immediately; stdout is runtime JSON. See README for environment overrides.' \
    'Reuses the existing Foundry account/project and Module-01 authorization; never changes RBAC.'
  exit 0
fi
(($# == 0)) || fail "No mode flags are needed; use: bash deploy-models.sh"

# 1. Read configuration and locate the existing Foundry account/project.
for tool in az jq; do command -v "$tool" >/dev/null || fail "Required tool missing: $tool"; done
subscription="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv | tr -d '\r\n')}"
resource_group="${RESOURCE_GROUP:-rg-agenthost-workshop}"
account="${FOUNDRY_RESOURCE_NAME:-}"
for key in subscription resource_group account; do
  printf -v "$key" '%s' "$(printf '%s' "${!key}" | tr -d '\r\n')"
done
if [[ -z "$account" ]]; then
  sn="${DEPLOYMENT_SN:-$(az group show --subscription "$subscription" -n "$resource_group" --query tags.deploymentSN -o tsv | tr -d '\r\n')}"
  sn="$(printf '%s' "$sn" | tr -d '\r\n')"
  [[ "$sn" =~ ^[a-zA-Z0-9-]+$ ]] || fail "Set FOUNDRY_RESOURCE_NAME or restore Module-01 deploymentSN"
  account="foundry-agenthost-$sn"
fi
project="$(printf '%s' "${FOUNDRY_PROJECT_NAME:-maf-agent-prj}" | tr -d '\r\n')"
account_info="$(az cognitiveservices account show --subscription "$subscription" -g "$resource_group" -n "$account" -o json)"
account_id="$(jq -er '.id | strings | select(length>0)' <<<"$account_info" | tr -d '\r\n')"
project_info="$(az resource show --ids "$account_id/projects/$project" --api-version 2026-03-01 -o json)" ||
  fail "Existing Foundry project not found; this stage never creates a project"
jq -e --arg id "$account_id/projects/$project" '(.id|ascii_downcase)==($id|ascii_downcase)' <<<"$project_info" >/dev/null ||
  fail "Foundry project ID mismatch"

# Module-01 builds its backend from properties.endpoint, which may use cognitiveservices.azure.com.
account_endpoint="$(jq -er '.properties.endpoint | strings | rtrimstr("/") |
  select(test("^https://[a-zA-Z0-9.-]+$"))' <<<"$account_info" | tr -d '\r\n')" ||
  fail "Existing Foundry account has no HTTPS account endpoint"
project_endpoint="$account_endpoint/api/projects/$project"
project_alias="https://$account.services.ai.azure.com/api/projects/$project"

common="${ACA_COMMON:-$root/.local/aca-common.json}"
deployment="${EMBEDDING_DEPLOYMENT_NAME:-}"
if [[ -f "$common" ]]; then
  # Confirm this is the account/project already used for Responses.
  configured_project="$(jq -r '.FOUNDRY_PROJECT_ENDPOINT // ""' "$common" | tr -d '\r\n')"
  if [[ -n "$configured_project" ]]; then
    [[ "${configured_project%/}" == "$project_endpoint" || "${configured_project%/}" == "$project_alias" ]] ||
      fail "FOUNDRY_PROJECT_ENDPOINT conflicts with the selected Foundry account/project"
  fi
  deployment="${deployment:-$(jq -r '.EMBEDDING_MODEL // ""' "$common" | tr -d '\r\n')}"
fi
deployment="${deployment:-text-embedding-3-small}"
model="${EMBEDDING_MODEL_NAME:-text-embedding-3-small}"
version="${EMBEDDING_MODEL_VERSION:-1}"
sku="${EMBEDDING_SKU:-GlobalStandard}"
capacity="${EMBEDDING_CAPACITY:-30}"
for key in deployment model version sku capacity; do
  printf -v "$key" '%s' "$(printf '%s' "${!key}" | tr -d '\r\n')"
done
[[ "$capacity" =~ ^[1-9][0-9]{0,5}$ ]] || fail "EMBEDDING_CAPACITY must be a positive integer"
[[ "$deployment" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]] || fail "Invalid embedding deployment name"
[[ "$model" == text-embedding-3-small || "$model" == text-embedding-3-large ]] ||
  fail "Use a text-embedding-3 model that supports the application's dimensions parameter"

# 2. Protect existing deployments: never change their model/version/SKU or reduce shared capacity.
deployments="$(az cognitiveservices account deployment list --subscription "$subscription" -g "$resource_group" -n "$account" -o json)"
existing="$(jq -c --arg name "$deployment" '[.[] | select(.name==$name)] |
  if length>1 then error("Duplicate deployment name") else .[0] // null end' <<<"$deployments" | tr -d '\r')"
if [[ "$existing" != null ]]; then
  jq -e --arg model "$model" --arg version "$version" --arg sku "$sku" '
    .properties.model.name==$model and .properties.model.version==$version and .sku.name==$sku
  ' <<<"$existing" >/dev/null || fail "Existing deployment uses a different model/version/SKU; choose another name"
  existing_capacity="$(jq -er '.sku.capacity | numbers' <<<"$existing" | tr -d '\r\n')"
  if ((existing_capacity > capacity)); then capacity="$existing_capacity"; fi
fi

# Resolve the actual account OpenAI endpoint, never the project inference endpoint.
endpoint="$(jq -er '.properties.endpoints["OpenAI Language Model Instance API"] |
  strings | rtrimstr("/") | select(test("^https://[a-zA-Z0-9.-]+$"))' <<<"$account_info" | tr -d '\r\n')" ||
  fail "Existing Foundry account has no HTTPS OpenAI inference endpoint"

# 3. Read Module-01 APIM and Agent identity; no parent resources or IAM are written.
identity="$(bash "$root/common/resolve-identity.sh")"
identity_id="$(jq -er '.AGENT_IDENTITY_RESOURCE_ID' <<<"$identity" | tr -d '\r\n')"
client_id="$(jq -er '.AGENT_IDENTITY_CLIENT_ID' <<<"$identity" | tr -d '\r\n')"
principal_id="$(jq -er '.AGENT_IDENTITY_PRINCIPAL_ID' <<<"$identity" | tr -d '\r\n')"
tenant_id="$(jq -er '.AZURE_TENANT_ID' <<<"$identity" | tr -d '\r\n')"
apim_name="$(printf '%s' "${APIM_NAME:-}" | tr -d '\r\n')"
if [[ -z "$apim_name" ]]; then
  sn="${DEPLOYMENT_SN:-$(az group show --subscription "$subscription" -n "$resource_group" --query tags.deploymentSN -o tsv | tr -d '\r\n')}"
  sn="$(printf '%s' "$sn" | tr -d '\r\n')"
  [[ "$sn" =~ ^[a-zA-Z0-9-]+$ ]] || fail "Set APIM_NAME or restore Module-01 deploymentSN"
  apim_name="apim-agenthost-$sn"
fi
apim_id="/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.ApiManagement/service/$apim_name"
apim="$(az resource show --ids "$apim_id" --api-version 2023-05-01-preview -o json)" ||
  fail "Existing Module-01 APIM not found"
jq -e --arg id "$apim_id" --arg identity "$identity_id" --arg client "$client_id" \
  --arg principal "$principal_id" --arg tenant "$tenant_id" '
  (.id|ascii_downcase)==($id|ascii_downcase) and
  (.identity.type | contains("SystemAssigned")) and
  (.identity.principalId | type=="string" and length>0) and
  .identity.tenantId==$tenant and
  any(.identity.userAssignedIdentities | to_entries[];
    (.key|ascii_downcase)==($identity|ascii_downcase) and
    .value.clientId==$client and .value.principalId==$principal)
  ' <<<"$apim" >/dev/null || fail "APIM system identity, tenant or attached Agent UAMI mismatch"
gateway_url="$(jq -er '.properties.gatewayUrl | strings | rtrimstr("/") |
  select(test("^https://[a-zA-Z0-9.-]+$"))' <<<"$apim" | tr -d '\r\n')" ||
  fail "APIM has no HTTPS gateway URL"
api_id="$apim_id/apis/workshop-ai-gateway"
api="$(az resource show --ids "$api_id" --api-version 2023-05-01-preview -o json)" ||
  fail "Existing workshop-ai-gateway API not found"
jq -e --arg id "$api_id" '(.id|ascii_downcase)==($id|ascii_downcase) and
  .properties.path=="foundry" and (.properties.protocols | index("https"))!=null' <<<"$api" >/dev/null ||
  fail "Existing APIM API ID/path/protocol mismatch"
backend="$(az resource show --ids "$apim_id/backends/foundry-backend" --api-version 2023-05-01-preview -o json)" ||
  fail "Existing Foundry backend not found"
backend_url="$(jq -er '.properties.url | strings | select(length>0)' <<<"$backend" | tr -d '\r\n')" ||
  fail "Existing Foundry backend has no URL"
[[ "${backend_url%/}" == "$project_endpoint" || "${backend_url%/}" == "$project_alias" ]] ||
  fail "APIM Responses backend conflicts with the selected Foundry account/project: actual=$backend_url; expected=$project_endpoint or $project_alias"
if [[ -f "$common" ]]; then
  jq -e --arg url "$gateway_url/foundry" --arg client "$client_id" --arg tenant "$tenant_id" '
    ((.AGENT_APIM_ENDPOINT // "" | rtrimstr("/")) | .=="" or .==$url) and
    ((.AZURE_CLIENT_ID // "") | .=="" or .==$client) and
    ((.AZURE_TENANT_ID // "") | .=="" or .==$tenant) and
    (.AZURE_CLIENT_SECRET // "")==""
    ' "$common" >/dev/null || fail "ACA_COMMON gateway or Agent identity conflicts with Module-01"
fi

printf 'Foundry target: %s/projects/%s; embedding=%s (%s/%s, %s x %s)\n' \
  "$account_id" "$project" "$deployment" "$model" "$version" "$sku" "$capacity" >&2

# 4. Let Azure validate model availability, quota and APIM policy; no fallback on failure.
# Refuse pre-existing children without a baseline rather than inventing their prior state.
source "$root/common/cleanup-ownership.sh"
ownership_begin_models "$account_id/deployments/$deployment" "$api_id/operations/embeddings" \
  "$apim_id/backends/module06-embeddings-backend" "$model"
deployment_rc=0
az deployment group create --subscription "$subscription" --resource-group "$resource_group" \
  --name module06-embedding --mode Incremental --template-file "$root/bicep/embedding.bicep" \
  --parameters "foundryAccountName=$account" \
  "deploymentName=$deployment" "modelName=$model" "modelVersion=$version" \
  "skuName=$sku" "capacity=$capacity" "apimName=$apim_name" "openAiEndpoint=$endpoint" \
  "gatewayUrl=$gateway_url" "tenantId=$tenant_id" "callerPrincipalId=$principal_id" --only-show-errors -o none ||
  deployment_rc=$?
# Also capture partial failures so cleanup can identify the children actually created.
ownership_finish_models
((deployment_rc == 0)) ||
  fail "Embedding deployment failed (model or APIM); inspect deployment operations for module06-embedding"
jq -e --argjson ids "$model_target_ids" 'all(.resources[]|select(.id as $id|$ids|index($id)!=null); .after!=null)' <<<"$ownership" >/dev/null ||
  fail "Embedding deployment reported success but expected children are missing; baseline retained"

jq -n --arg url "$gateway_url/foundry/openai/v1" --arg model "$deployment" \
  --arg apim "$apim_id" --arg caller "$principal_id" \
  '{FOUNDRY_EMBEDDING_BASE_URL:$url,EMBEDDING_MODEL:$model,
    EMBEDDING_TOKEN_SCOPE:"https://ai.azure.com/.default",EMBEDDING_GATEWAY_VERSION:"1",
    EMBEDDING_GATEWAY_APIM_ID:$apim,EMBEDDING_GATEWAY_CALLER_OBJECT_ID:$caller}'
