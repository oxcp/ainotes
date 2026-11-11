#!/usr/bin/env bash
# deploy.sh -- Module 6: staged multi-agent deployment (workshop path).
#
# Reuses the shared infrastructure from earlier modules and runs:
#   1. Validate inputs and required tools
#   2. Create the private data container and deploy embeddings in the existing Foundry project
#   3. Deploy the selected database and generate protected configuration
#   4. Build five Agent images in ACR and deploy ACA Sandboxes
#
# Usage: bash deploy.sh --migrate
# Prerequisites: Modules 1 and 4 deployed; see --help for tools and overrides.

# Disable command tracing before handling secrets; newly created files are owner-only.
set +x
set -euo pipefail
umask 077

# -- Helpers and command-line options ----------------------------------------
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  cat <<'HELP'
Usage: bash deploy.sh [--stage all|storage|models|database|config|images|aca]
                      [--provider horizondb|postgresql] [--migrate]
Runs preflight checks, then storage -> models -> database -> config -> images -> aca.
Running this script deploys billable resources; review provider, network access and cost first.
--stage selects one stage for a deliberate retry; it is NOT an automatic resume.
--migrate explicitly enables initial schema migration in the ACA guests.

Configure through environment variables (stage-specific flags remain on stage scripts):
  DB_PROVIDER, SUBSCRIPTION_ID, RESOURCE_GROUP, LOCATION, DEPLOYMENT_SN,
  DB_LOCATION (database-only region; does not change SandboxGroup location),
  DB_RESOURCE_NAME, DB_USERNAME, DB_VCORES / DB_SKU_NAME / DB_STORAGE_SIZE_GB,
  DB_REUSE_ENTRA_ADMIN (optional existing-only guard; HorizonDB admin is created/verified automatically),
  DB_FIREWALL_RULES_FILE, ACR_NAME, IMAGE_TAG, SANDBOX_GROUP_NAME,
  REGISTRY_IDENTITY, CUSTOMER_VNET_CONNECTION_NAME, SANDBOX_CPU, SANDBOX_MEMORY.
  STORAGE_ACCOUNT_NAME, STORAGE_SUBSCRIPTION_ID, STORAGE_RESOURCE_GROUP (optional),
  KB_STORAGE_CONTAINER_ID (optional target, derived automatically from the reused account),
  KB_VOLUME_NAME (studio-kb-data), KB_VOLUME_IDENTITY (defaults to registry identity).
  AGENT_IDENTITY_RESOURCE_ID (otherwise Module-01 IDENTITY_NAME / id-agenthost-<SN>).
  FOUNDRY_RESOURCE_NAME, FOUNDRY_PROJECT_NAME (maf-agent-prj), EMBEDDING_DEPLOYMENT_NAME,
  EMBEDDING_MODEL_NAME (text-embedding-3-small), EMBEDDING_MODEL_VERSION (1),
  EMBEDDING_SKU (GlobalStandard), EMBEDDING_CAPACITY (30), APIM_NAME (apim-agenthost-<SN>).
  LLM_MODEL (otherwise Module-01 main-<SN> deployment output), EMBEDDING_DIMENSIONS (1536).
Protected inputs/outputs default to module-06/.local (outside image context):
  ACA_COMMON (optional custom JSON input; never overwritten, must already exist)
  .local/aca-common.json (auto-generated from current Module-01 resources during preflight)
  DB_PASSWORD_FILE=.local/database-password (or DB_PASSWORD on initial creation)
  DB_OUTPUT=.local/database-deployment.json
  ACA_CONFIG=.local/aca-config.json
  ACA_OUTPUT=.local/aca-deployment.json
Models extends the existing APIM and saves gateway metadata to .local/embedding-config.json.
Full runs refresh the default common JSON for the current SN; config-only retries reuse it.
Do not edit the generated default: set ACA_COMMON to a separate file for custom settings.
Config retries reject older direct-endpoint metadata; rerun --stage models to upgrade.
Explicit relative file paths are relative to the CALLER's directory, not module-06.
The peer key is generated once in module-06/.local/a2a-key; never logged.
Existing DB/ACA inventories and config are never overwritten. Preserve them before retry.
Preflight checks cannot guarantee Azure capacity, permissions, DB connectivity or image availability.
Storage creates only private data via incremental ARM; account/blob service remain existing.
Database stage performs ARM validation before provision; ACA validates manifests before apply.
Requires Bash, jq, az; config generation also openssl; ACA also aca, curl, timeout.
No host Python, PowerShell, Docker or shared infrastructure deployment.
Default public DB firewall and anonymous HTTPS ingress are workshop-only.
HELP
}
fail() {
  printf 'Error [%s]: %s\n' "$stage" "$*" >&2
  exit 1
}
# Keep discovery variables, exports and failures separate from the deployment state.
resolve_common() (
  set +x
  set -euo pipefail
  trap - EXIT INT TERM
  fail() { printf 'Error [common]: %s\n' "$*" >&2; exit 1; }
  for tool in az jq; do command -v "$tool" >/dev/null || fail "Required tool missing: $tool"; done
  export SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
  export RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
  for key in SUBSCRIPTION_ID RESOURCE_GROUP DEPLOYMENT_SN FOUNDRY_RESOURCE_NAME APIM_NAME LLM_MODEL \
    EMBEDDING_DEPLOYMENT_NAME EMBEDDING_DIMENSIONS; do
    if [[ -v "$key" ]]; then export "$key=$(printf '%s' "${!key}" | tr -d '\r\n')"; fi
  done
  export DEPLOYMENT_SN="${DEPLOYMENT_SN:-$(az group show --subscription "$SUBSCRIPTION_ID" \
    -n "$RESOURCE_GROUP" --query tags.deploymentSN -o tsv | tr -d '\r\n')}"
  [[ "$DEPLOYMENT_SN" =~ ^[a-zA-Z0-9-]+$ && "$DEPLOYMENT_SN" != null ]] ||
    fail "Set DEPLOYMENT_SN or restore the Module-01 resource group deploymentSN tag"
  account="${FOUNDRY_RESOURCE_NAME:-foundry-agenthost-$DEPLOYMENT_SN}"
  apim="${APIM_NAME:-apim-agenthost-$DEPLOYMENT_SN}"
  model="${LLM_MODEL:-}"
  if [[ -z "$model" ]]; then
    outputs="$(az deployment sub show --subscription "$SUBSCRIPTION_ID" --name "main-$DEPLOYMENT_SN" \
      --query properties.outputs -o json)" ||
      fail "Cannot read Module-01 deployment main-$DEPLOYMENT_SN; set LLM_MODEL to the deployed general-model name"
    model="$(jq -er --arg group "$RESOURCE_GROUP" --arg account "$account" '
      select((.resourceGroupName.value|ascii_downcase)==($group|ascii_downcase) and
        (.foundryResourceName.value|ascii_downcase)==($account|ascii_downcase)) |
      .modelDeploymentName.value | strings | select(length>0)
    ' <<<"$outputs" | tr -d '\r\n')" ||
      fail "Module-01 outputs do not match the selected group/account; set LLM_MODEL explicitly"
  fi
  deployment="$(az cognitiveservices account deployment show --subscription "$SUBSCRIPTION_ID" \
    -g "$RESOURCE_GROUP" -n "$account" --deployment-name "$model" -o json)" ||
    fail "Cannot read general-model deployment $model in $account"
  jq -e --arg model "$model" '.name==$model and .properties.provisioningState=="Succeeded" and
    .properties.model.format=="OpenAI" and (.properties.model.name | startswith("text-embedding-") | not)
    ' <<<"$deployment" >/dev/null || fail "LLM_MODEL must select a successfully deployed general model"
  apim_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$apim"
  gateway="$(az resource show --ids "$apim_id" --api-version 2023-05-01-preview -o json)" ||
    fail "Cannot read existing Module-01 APIM"
  gateway_url="$(jq -er '.properties.gatewayUrl | strings | rtrimstr("/") |
    select(test("^https://[a-zA-Z0-9.-]+$"))' <<<"$gateway" | tr -d '\r\n')" ||
    fail "APIM has no HTTPS gateway URL"
  storage="$(bash "$root/deploy-storage.sh" --discover)" || fail "Cannot discover existing Module-01 storage"
  jq -n --argjson storage "$storage" --arg gateway "$gateway_url/foundry" --arg model "$model" \
    --arg embedding "${EMBEDDING_DEPLOYMENT_NAME:-text-embedding-3-small}" \
    --arg dimensions "${EMBEDDING_DIMENSIONS:-1536}" '
    {BLOB_BACKEND:"azure",AZURE_STORAGE_ACCOUNT_URL:$storage.AZURE_STORAGE_ACCOUNT_URL,
     AZURE_STORAGE_CONTAINER:"data",AGENT_APIM_ENDPOINT:$gateway,LLM_MODEL:$model,
     EMBEDDING_MODEL:$embedding,EMBEDDING_DIMENSIONS:$dimensions}'
)
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
# -- Configuration ----------------------------------------------------------
stage=preflight selected=all migrate=false
# Parse flags first so explicit choices take precedence over environment defaults.
while (($#)); do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --migrate)
      migrate=true
      shift
      ;;
    --stage | --provider)
      (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || fail "Missing value for $1"
      if [[ "$1" == --stage ]]; then selected="$2"; else export DB_PROVIDER="$2"; fi
      shift 2
      ;;
    *) fail "Unknown option: $1 (use --help)" ;;
  esac
done
case "$selected" in all | storage | models | database | config | images | aca) ;; *) fail "Invalid stage: $selected" ;; esac
# Environment metadata may come from Windows CLI command substitutions in WSL; preserve secrets and paths.
for key in SUBSCRIPTION_ID RESOURCE_GROUP LOCATION DEPLOYMENT_SN DB_PROVIDER AGENT_IDENTITY_RESOURCE_ID \
  IDENTITY_NAME ACR_NAME IMAGE_TAG SANDBOX_GROUP_NAME STORAGE_ACCOUNT_NAME STORAGE_SUBSCRIPTION_ID \
  STORAGE_RESOURCE_GROUP KB_STORAGE_CONTAINER_ID KB_VOLUME_NAME KB_VOLUME_IDENTITY; do
  if [[ -v "$key" ]]; then
    value="$(printf '%s' "${!key}" | tr -d '\r\n')"
    export "$key=$value"
  fi
done
export DB_PROVIDER="${DB_PROVIDER:-horizondb}"
case "$DB_PROVIDER" in horizondb | postgresql) ;; *) fail "DB_PROVIDER must be horizondb or postgresql" ;; esac
export DB_PASSWORD_FILE="${DB_PASSWORD_FILE:-$root/.local/database-password}"
export DB_OUTPUT="${DB_OUTPUT:-$root/.local/database-deployment.json}"
export ACA_CONFIG="${ACA_CONFIG:-$root/.local/aca-config.json}"
export ACA_OUTPUT="${ACA_OUTPUT:-$root/.local/aca-deployment.json}"
common="${ACA_COMMON:-$root/.local/aca-common.json}"
custom_common="${ACA_COMMON:-}"
# A single-stage retry requires its earlier-stage artifacts; it does not rerun dependencies.
wants() { [[ "$selected" == all || "$selected" == "$1" ]]; }
# -- Validate the selected stages before making changes ----------------------
stage=preflight
[[ ! -L "$root/.local" ]] || fail "Artifact directory must not be a symbolic link"
for tool in jq az; do command -v "$tool" >/dev/null || fail "Required tool missing: $tool"; done
for file in common/resolve-identity.sh deploy-models.sh deploy-storage.sh deploy-database.sh build-images.sh deploy-aca.sh; do bash -n "$root/$file"; done
identity_settings='{}'
model_settings='{}'
if wants database || wants config || wants aca; then
  stage=identity
  identity_settings="$(bash "$root/common/resolve-identity.sh")"
  while IFS=$'\t' read -r key value; do export "$key=$value"; done \
    < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"$identity_settings" | tr -d '\r')
  stage=preflight
fi
export ACA_COMMON="$common"
if wants config; then
  command -v openssl >/dev/null || fail "Required tool missing: openssl"
  [[ ! -L "$common" ]] || fail "ACA_COMMON must not be a symbolic link"
  [[ ! -e "$common" || -f "$common" ]] || fail "ACA_COMMON must be a regular file"
  if [[ -z "$custom_common" && ( "$selected" == all || ! -e "$common" ) ]]; then
    [[ ! -e "$ACA_CONFIG" ]] || fail "ACA_CONFIG exists; preserve it and choose another output before regenerating common settings"
    common_settings="$(resolve_common)"
  else
    [[ -f "$common" ]] || fail "Explicit ACA_COMMON file not found: $common"
    common_settings="$(cat -- "$common")"
  fi
  jq -e '(.AZURE_CLIENT_SECRET // "")==""' <<<"$common_settings" >/dev/null ||
    fail "Remove AZURE_CLIENT_SECRET from ACA_COMMON; the primary cloud path uses Module-01 UAMI"
  # Synthetic DB/key values validate common settings without generating credentials or files.
  jq -e '
      . + {FOUNDRY_EMBEDDING_BASE_URL:((.AGENT_APIM_ENDPOINT // "" | rtrimstr("/")) + "/openai/v1"),
      EMBEDDING_TOKEN_SCOPE:"https://ai.azure.com/.default",
      DB_PROVIDER:env.DB_PROVIDER,DB_AUTH_MODE:"password",DB_ENDPOINT:"validation.example.test",DB_PORT:"5432",
      DB_DATABASE:"postgres",DB_USERNAME:"studioadmin",DB_PASSWORD:"validation-only",
      DB_SSL_MODE:"require",
      A2A_API_KEY:"validation-peer-key-000000000000"} as $env |
      ["chat","orchestrator","data-processing","rag","sql"] |
      map({key:.,value:$env}) | from_entries
    ' <<<"$common_settings" | jq -e -f "$root/common/aca-config.jq" >/dev/null ||
    fail "Invalid ACA_COMMON: check Azure Blob, HTTPS model endpoints, model names and authentication"
  if [[ -z "$custom_common" && ( "$selected" == all || ! -e "$common" ) ]]; then
    mkdir -p -- "$root/.local"
    chmod 700 "$root/.local"
    common_tmp="$(mktemp "$root/.local/common.XXXXXX")"
    trap 'rm -f -- "$common_tmp"' EXIT
    printf '%s\n' "$common_settings" >"$common_tmp"
    chmod 600 "$common_tmp"
    mv -- "$common_tmp" "$common"
    trap - EXIT
    printf 'Generated common settings from current Module-01 resources: %s\n' "$common" >&2
  fi
fi
if wants storage || wants aca; then
  stage=storage
  export ACA_COMMON="$common"
  # Resolve reads the existing account and derives the container ID without provisioning.
  KB_STORAGE_CONTAINER_ID="$(bash "$root/deploy-storage.sh" --resolve | tr -d '\r\n')" || fail "Cannot resolve existing storage account"
  export KB_STORAGE_CONTAINER_ID
  stage=preflight
fi
if wants aca; then
  for tool in aca curl timeout openssl; do command -v "$tool" >/dev/null || fail "Required tool missing: $tool"; done
  bash "$root/deploy-aca.sh" --capabilities
  if [[ "$selected" == aca ]]; then
    [[ -f "$ACA_CONFIG" ]] || fail "ACA_CONFIG missing; run --stage config first"
    jq -e -f "$root/common/aca-config.jq" "$ACA_CONFIG" >/dev/null || fail "Invalid ACA_CONFIG"
    jq -e 'all(.[]; (.DB_PROVIDER // "horizondb") == env.DB_PROVIDER)' "$ACA_CONFIG" >/dev/null ||
      fail "ACA_CONFIG provider differs from DB_PROVIDER"
  fi
fi
if [[ "$selected" == config ]]; then
  model_settings="$(jq -e --slurpfile common "$common" --argjson identity "$identity_settings" 'select(
      .EMBEDDING_GATEWAY_VERSION=="1" and
      (.EMBEDDING_GATEWAY_APIM_ID | type=="string" and test("/providers/Microsoft.ApiManagement/service/";"i")) and
      .EMBEDDING_GATEWAY_CALLER_OBJECT_ID==$identity.AGENT_IDENTITY_PRINCIPAL_ID and
      .FOUNDRY_EMBEDDING_BASE_URL==(($common[0].AGENT_APIM_ENDPOINT | rtrimstr("/")) + "/openai/v1") and
      (.EMBEDDING_MODEL | type=="string" and length>0) and
      .EMBEDDING_TOKEN_SCOPE=="https://ai.azure.com/.default")
    ' "$root/.local/embedding-config.json")" ||
    fail "Config requires matching APIM metadata in .local/embedding-config.json; run --stage models first"
  [[ -f "$DB_PASSWORD_FILE" && -f "$DB_OUTPUT" ]] || fail "Config requires DB_PASSWORD_FILE and provisioned DB_OUTPUT"
  [[ ! -L "$DB_PASSWORD_FILE" ]] || fail "Password file must not be a symbolic link"
  jq -e '.status=="provisioned" and .DB_PROVIDER==env.DB_PROVIDER' "$DB_OUTPUT" >/dev/null ||
    fail "DB_OUTPUT must be provisioned and match DB_PROVIDER"
fi
# Isolate the sourced guard's variables/functions; never run the direct builder during preflight.
if wants images; then
  (source "$root/build-images.sh"; images_preflight) || fail "Image preflight failed"
fi
if wants database; then
  for tool in openssl mktemp; do command -v "$tool" >/dev/null || fail "Required tool missing: $tool"; done
  [[ ! -L "$DB_PASSWORD_FILE" ]] || fail "Password file must not be a symbolic link"
fi
printf 'Preflight passed: provider=%s stage=%s. Starting deployment.\n' "$DB_PROVIDER" "$selected"

# Inventories identify real resources after partial failures; never overwrite them on a retry.
if wants database; then [[ ! -e "$DB_OUTPUT" ]] || fail "DB_OUTPUT exists; preserve inventory and choose another output"; fi
if wants config; then [[ ! -e "$ACA_CONFIG" ]] || fail "ACA_CONFIG exists; preserve it and choose another output"; fi
if wants aca; then [[ ! -e "$ACA_OUTPUT" ]] || fail "ACA_OUTPUT exists; preserve inventory and choose another output"; fi
if wants models; then [[ ! -L "$root/.local/embedding-config.json" ]] || fail "Embedding metadata must not be a symbolic link"; fi
stage=prepare
# -- Prepare protected deployment files -------------------------------------
mkdir -p -- "$root/.local"
chmod 700 "$root/.local"
if wants database; then
  mkdir -p -- "$(dirname -- "$DB_PASSWORD_FILE")"
  [[ ! -L "$DB_PASSWORD_FILE" ]] || fail "Password file must not be a symbolic link"
  if [[ ! -f "$DB_PASSWORD_FILE" ]]; then
    if [[ -n "${DB_PASSWORD:-}" ]]; then
      printf '%s' "$DB_PASSWORD" >"$DB_PASSWORD_FILE"
    else
      command -v openssl >/dev/null || fail "Required tool missing: openssl"
      openssl rand -base64 36 >"$DB_PASSWORD_FILE"
    fi
  fi
  chmod 600 "$DB_PASSWORD_FILE"
fi
unset DB_PASSWORD
trap 'rc=$?; printf "Error [%s]: stage stopped (exit %s); no later stages ran. Preserve inventories; no rollback. Retry deliberately with --stage.\\n" "$stage" "$rc" >&2; exit "$rc"' ERR
# -- Run stages in dependency order -----------------------------------------
if wants storage; then
  stage=storage
  printf '\n[storage] Private data container in existing Module-01 account (incremental ARM)\n'
  bash "$root/deploy-storage.sh"
fi
if wants models; then
  stage=models
  printf '\n[models] Existing Foundry embedding deployment + APIM operation; Module-01 authorization unchanged\n'
  # A failed model/APIM update must not leave old metadata eligible for config retries.
  rm -f -- "$root/.local/embedding-config.json"
  model_settings="$(bash "$root/deploy-models.sh")"
  printf '%s\n' "$model_settings" >"$root/.local/embedding-config.json"
fi
if wants database; then
  stage=database
  printf '\n[database] ARM validation and provisioning\n'
  bash "$root/deploy-database.sh" --password-file "$DB_PASSWORD_FILE"
fi
if wants config; then
  stage=config
  printf '\n[config] Merge protected common settings and DB manifest\n'
  [[ -f "$DB_PASSWORD_FILE" ]] || fail "Database password file missing"
  jq -e '.status=="provisioned" and .DB_PROVIDER==env.DB_PROVIDER' "$DB_OUTPUT" >/dev/null ||
    fail "DB_OUTPUT must be provisioned and match DB_PROVIDER"
  # Browser access is keyless; only Agent-to-Agent calls need a shared secret.
  [[ ! -L "$root/.local/a2a-key" ]] || fail "Key must not be a symbolic link"
  [[ -f "$root/.local/a2a-key" ]] || openssl rand -hex 32 >"$root/.local/a2a-key"
  chmod 600 "$root/.local/a2a-key"
  chmod 600 "$common" "$DB_PASSWORD_FILE"
  tmp="$(mktemp -d "$root/.local/config.XXXXXX")"
  trap 'rm -f -- "$tmp/config.json"; rmdir -- "$tmp"' EXIT
  # Merge only DB_* outputs into common settings; all five roles share the same data/auth contract.
  # --rawfile keeps passwords and keys out of literal process arguments and console output.
  jq -n --slurpfile common "$common" --slurpfile db "$DB_OUTPUT" \
    --argjson identity "$identity_settings" --argjson models "$model_settings" \
    --rawfile password "$DB_PASSWORD_FILE" \
    --rawfile peer "$root/.local/a2a-key" '
      (($common[0] | del(.DB_PASSWORD,.STUDIO_API_KEY)) + ($db[0] | with_entries(select(.key | startswith("DB_")))) + $models +
       {AZURE_CLIENT_ID:$identity.AGENT_IDENTITY_CLIENT_ID,AZURE_TENANT_ID:$identity.AZURE_TENANT_ID} +
       (if ($db[0].DB_AUTH_MODE // "password")=="entra" then {DB_AUTH_MODE:"entra"}
        else {DB_PASSWORD:($password|sub("\r?\n$";""))} end) +
       {
        A2A_API_KEY:($peer|sub("\r?\n$";""))}) as $env |
      ["chat","orchestrator","data-processing","rag","sql"] |
      map({key:.,value:$env}) | from_entries
    ' >"$tmp/config.json"
  jq -e -f "$root/common/aca-config.jq" "$tmp/config.json" >/dev/null || fail "Merged ACA configuration invalid"
  mkdir -p -- "$(dirname -- "$ACA_CONFIG")"
  # Publish only a fully validated file so the ACA stage cannot consume a partial configuration.
  mv -- "$tmp/config.json" "$ACA_CONFIG"
  chmod 600 "$ACA_CONFIG"
  rmdir -- "$tmp"
  trap - EXIT
fi
if wants images; then
  stage=images
  printf '\n[images] Five remote ACR builds (agent-src context)\n'
  bash "$root/build-images.sh"
fi
if wants aca; then
  stage=aca
  printf '\n[aca] Validate manifests, deploy, configure and check five Agents\n'
  args=()
  # Provisioning a database does not create application tables; migration remains explicit.
  if $migrate; then args+=(--migrate); fi
  bash "$root/deploy-aca.sh" "${args[@]}"
fi
printf '\nSelected deployment stages completed. Live workflow acceptance remains required.\n'
