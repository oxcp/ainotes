#!/usr/bin/env bash
# deploy-aca.sh -- Module 6: deploy five Agents to the existing ACA SandboxGroup.
#
#   1. Validate inputs, CLI capabilities and protected configuration
#   2. Verify or create the shared Blob volume
#   3. Import images, create Sandboxes and mount data for Chat/Data Processing
#   4. Upload runtime configuration, check the database and activate Agents
#   5. Verify health, Agent Cards and the Chat-to-Orchestrator route
#
# Usage: bash deploy-aca.sh [--migrate]
# Env overrides: ACA_CONFIG, ACA_OUTPUT, KB_STORAGE_CONTAINER_ID and others in --help.
# Prerequisites: Module 4 SandboxGroup, Module 6 storage/database/images; see --help.

set +x
set -euo pipefail
umask 077

# -- Helpers and command-line options ----------------------------------------
usage() {
  cat <<'HELP'
Usage: bash deploy-aca.sh [options]
  --subscription ID          SUBSCRIPTION_ID; otherwise current az account
  --resource-group NAME      Existing Module-01 RG (RESOURCE_GROUP or rg-agenthost-workshop)
  --region REGION            LOCATION; otherwise existing RG location
  --sandbox-group NAME       SANDBOX_GROUP_NAME or sandbox-group-agenthost-<SN>
  --registry HOST            ACR_LOGIN_SERVER; otherwise query ACR_NAME or acragenthost<SN>
  --registry-identity ID     REGISTRY_IDENTITY; otherwise query IDENTITY_NAME or id-agenthost-<SN>
                            Agent access uses AGENT_IDENTITY_RESOURCE_ID (Module-01 UAMI), independently
  --tag TAG                  IMAGE_TAG or latest (Module-04 convention)
  --vnet-connection NAME     CUSTOMER_VNET_CONNECTION_NAME; otherwise discover the group's sole connection
                            Selected existing connection is used by all five Agents
  --config FILE              ACA_CONFIG or .local/aca-config.json (protected five-role JSON map)
  --output FILE              ACA_OUTPUT or .local/aca-deployment.json
  --health-timeout SECONDS   HEALTH_TIMEOUT_SECONDS or 180
  --operation-timeout SEC    OPERATION_TIMEOUT_SECONDS or 900
  --cpu QUANTITY             SANDBOX_CPU or 1000m
  --memory QUANTITY          SANDBOX_MEMORY or 2048Mi
  --auto-suspend-mins MINS   AUTO_SUSPEND_MINS or 0 (disabled; positive minutes opt in)
  --migrate                 Apply the existing application schema before starting Agents
  --capabilities            Read-only volume/mount capability preflight (standalone operation)
  --help
Requires Bash, az, aca (tested: 1.0.0-preview.5), jq, curl, timeout and openssl.
No local Python SDK, Docker builds, group creation or automatic resource deletion.
Mount: KB_STORAGE_CONTAINER_ID is the existing private data container ARM ID.
KB_VOLUME_NAME defaults to studio-kb-data; KB_VOLUME_IDENTITY defaults to the registry identity
(system or a user-assigned identity already on the group, with Storage Blob Data Reader).
Uses a shared group AzureBlobByo volume, mounted read-only at /kb-data on Chat and Data Processing only.
All five guests inherit the Module-01 UAMI from the existing group; it is assigned if missing.
Runtime AZURE_CLIENT_ID is pinned to that UAMI; image import identity does not select Agent credentials.
Precedence: explicit flags > environment > defaults. SN: DEPLOYMENT_SN or RG deploymentSN tag.
Running this script creates five billable Sandboxes after automatic validation.
Schema migration requires explicit --migrate; the number of Agents is always five.
HELP
}
fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
volume_preflight() {
  local help key
  for key in KB_STORAGE_CONTAINER_ID KB_VOLUME_NAME; do
    if [[ -v "$key" ]]; then
      help="$(printf '%s' "${!key}" | tr -d '\r\n')"
      export "$key=$help"
    fi
  done
  # Preview CLI surfaces vary; verify actual flags before spending time importing images.
  command -v aca >/dev/null || fail "Required tool missing: aca"
  help="$(aca sandboxgroup volume create --help)" ||
    fail "ACA volume capability check failed"
  [[ "$help" == *AzureBlobByo* && "$help" == *--storage-container-id* &&
    "$help" == *--identity-kind* && "$help" == *--identity-resource-id* ]] ||
    fail "Upgrade aca: AzureBlobByo with managed-identity authentication is required"
  help="$(aca sandbox mount --help)" || fail "ACA mount capability check failed"
  [[ "$help" == *--readonly* && "$help" == *--volume* && "$help" == *--path* ]] ||
    fail "Upgrade aca: read-only runtime volume mounts are required"
  [[ "${KB_STORAGE_CONTAINER_ID:-}" =~ ^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[^/]+/blobServices/default/containers/data$ ]] ||
    fail "Set KB_STORAGE_CONTAINER_ID to the existing data container ARM resource ID"
  [[ "${KB_VOLUME_NAME:-studio-kb-data}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] ||
    fail "Invalid KB_VOLUME_NAME"
}
if [[ $# == 1 && "$1" == --capabilities ]]; then
  volume_preflight
  exit 0
fi
# -- Configuration ----------------------------------------------------------
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
resource_group="${RESOURCE_GROUP:-rg-agenthost-workshop}"
subscription="${SUBSCRIPTION_ID:-}"
region="${LOCATION:-}"
sandbox_group="${SANDBOX_GROUP_NAME:-}"
registry="${ACR_LOGIN_SERVER:-}"
identity="${REGISTRY_IDENTITY:-}"
config="${ACA_CONFIG:-$root/.local/aca-config.json}"
vnet="${CUSTOMER_VNET_CONNECTION_NAME:-}"
tag="${IMAGE_TAG:-latest}"
output="${ACA_OUTPUT:-$root/.local/aca-deployment.json}"
health_timeout="${HEALTH_TIMEOUT_SECONDS:-180}"
operation_timeout="${OPERATION_TIMEOUT_SECONDS:-900}"
cpu="${SANDBOX_CPU:-1000m}"
memory="${SANDBOX_MEMORY:-2048Mi}"
auto_suspend_mins="${AUTO_SUSPEND_MINS:-0}"
migrate=false
roles=(chat orchestrator data-processing rag sql)
# All five roles deploy, but only these two need a filesystem view of the shared container.
mount_roles=(chat data-processing)
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
    --subscription | --resource-group | --region | --sandbox-group | --registry | --registry-identity | --tag | --vnet-connection | --config | --output | --health-timeout | --operation-timeout | --cpu | --memory | --auto-suspend-mins)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || fail "Missing value for $1"
      case "$1" in
        --subscription) subscription="$2" ;; --region) region="$2" ;;
        --resource-group) resource_group="$2" ;; --sandbox-group) sandbox_group="$2" ;;
        --registry) registry="$2" ;; --registry-identity) identity="$2" ;; --tag) tag="$2" ;;
        --vnet-connection) vnet="$2" ;; --config) config="$2" ;; --output) output="$2" ;;
        --health-timeout) health_timeout="$2" ;; --operation-timeout) operation_timeout="$2" ;;
        --cpu) cpu="$2" ;; --memory) memory="$2" ;; --auto-suspend-mins) auto_suspend_mins="$2" ;;
      esac
      shift 2
      ;;
    *) fail "Unknown option: $1" ;;
  esac
done
# Only normalize deployment metadata; protected JSON and credentials remain unchanged.
for key in subscription resource_group region sandbox_group registry identity vnet tag health_timeout \
  operation_timeout cpu memory auto_suspend_mins; do
  printf -v "$key" '%s' "$(printf '%s' "${!key}" | tr -d '\r\n')"
done
for tool in jq aca mktemp; do command -v "$tool" >/dev/null || fail "Required tool missing: $tool"; done
[[ -f "$config" ]] || fail "--config must name a protected five-role JSON file"
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail "Invalid image tag"
for value in "$health_timeout" "$operation_timeout"; do
  [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || fail "Timeouts must be positive integers of at most five digits"
done
[[ "$auto_suspend_mins" =~ ^(0|[1-9][0-9]{0,4})$ ]] ||
  fail "Auto-suspend minutes must be 0 (disabled) or a positive integer of at most five digits"
[[ "$cpu" =~ ^[1-9][0-9]*m?$ ]] || fail "CPU must be positive cores or millicores (for example 1000m)"
[[ "$memory" =~ ^[1-9][0-9]*(Mi|Gi)$ ]] || fail "Memory must use Mi or Gi (for example 2048Mi)"
[[ ! -e "$output" ]] || fail "Output already exists; preserve the inventory and use a new --output"
jq -e -f "$root/common/aca-config.jq" "$config" >/dev/null ||
  fail "Invalid configuration: check five roles, distinct shared keys, DB TLS, Azure Blob, models and common data settings"
jq -e 'all(.[]; (.AZURE_CLIENT_SECRET // "")=="")' "$config" >/dev/null ||
  fail "Remove service-principal secrets; all five Agents must use the Module-01 UAMI"
volume_preflight
volume_name="${KB_VOLUME_NAME:-studio-kb-data}"
container_id="$KB_STORAGE_CONTAINER_ID"
# The same read-only probe runs before activation and on every mounted guest process start.
# Check as the application UID, not root, to catch mounts the Agent cannot actually read.
mount_probe='import os
from pathlib import Path
p=Path("/kb-data")
if not os.path.ismount(p):
    raise SystemExit("/kb-data is not a mountpoint")
if os.getuid()==0:
    os.setgroups([])
    os.setgid(10001)
    os.setuid(10001)
if os.getuid()!=10001 or not os.access(p,os.R_OK|os.X_OK):
    raise SystemExit("/kb-data must be readable by UID 10001")
list(p.iterdir())
def walk_error(error):
    raise error
for directory, _, names in os.walk(p,onerror=walk_error):
    if names:
        with (Path(directory)/names[0]).open("rb") as stream:
            stream.read(1)
        break'

mkdir -p -- "$root/.local"
chmod 700 "$root/.local"
tmp="$(mktemp -d "$root/.local/aca-deploy.XXXXXX")"
recorded=false
stage="local-validation"
active_role=""
summary() {
  printf '\n%-17s %-12s %s\n' "AGENT" "STATUS" "URL"
  jq -r '.agents | to_entries[] | [.key,.value.status,(.value.url // "-")] | @tsv' "$output" |
    tr -d '\r' |
    while IFS=$'\t' read -r role status url; do printf '%-17s %-12s %s\n' "$role" "$status" "$url"; done
  printf 'Inventory: %s\n' "$output"
}
cleanup() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)); then
    printf 'Error: ACA deployment failed at %s (%s). No automatic rollback.\n' "$stage" "${active_role:-all roles}" >&2
    # Preserve IDs and the failing role/stage for inspection; do not delete resources on failure.
    if $recorded; then
      jq --arg stage "$stage" --arg role "$active_role" \
        '.status="failed" | .failed_stage=$stage | .failed_role=$role |
                 if $role != "" then .agents[$role].status="failed" else . end' \
        "$output" >"$tmp/inventory.json" && mv -- "$tmp/inventory.json" "$output"
    fi
  fi
  if $recorded; then summary; fi
  rm -f -- "$tmp/config.json" "$tmp/runtime.json" "$tmp/peer-header" "$tmp/browser-header" \
    "$tmp/manifest.json" "$tmp/response.json" "$tmp/health.json" "$tmp/card.json" \
    "$tmp/inventory.json" "$tmp/probe.json"
  rmdir -- "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -- "$config" "$tmp/config.json"
config="$tmp/config.json"

manifest() {
  local role="$1" disk="$2"
  # Wait for an explicit start marker; importing other images must not exhaust bootstrap's 600s timeout.
  local boot='umask 077; cd /app; deadline=$(($(date +%s)+3600)); while [ ! -f /app/.local/studio-start ]; do if [ "$(date +%s)" -ge "$deadline" ]; then echo "Configuration activation timed out" >&2; exit 1; fi; sleep 1; done; '
  case "$role" in
    chat | data-processing) boot+='python -c '"'$mount_probe'"' && ' ;;
  esac
  boot+="exec python -m shared.sandbox_bootstrap $role"
  jq -n --arg disk "$disk" --arg role "$role" --arg deployment "${deployment_id:-validation}" \
    --arg boot "$boot" --arg vnet "$vnet" --arg cpu "$cpu" --arg memory "$memory" \
    --argjson suspend "$((auto_suspend_mins * 60))" '{
        diskId:$disk, resources:{cpu:$cpu,memory:$memory},
        entrypoint:["/bin/sh","-c"], cmd:[$boot],
        labels:{role:$role,deployment:$deployment},
        lifecycle:{autoSuspendPolicy:{enabled:($suspend>0),interval:$suspend,mode:"Memory"}},
        egressPolicy:{defaultAction:"Allow",trafficInspection:(if $role=="chat" then "Full" else "Partial" end)}
      } + (if $vnet == "" then {} else {customerVnetConnectionName:$vnet} end)' >"$tmp/manifest.json"
}
# Validate locally with a placeholder disk ID; this does not prove image or Azure capacity availability.
manifest chat "00000000-0000-0000-0000-000000000001"
aca sandbox validate --file "$tmp/manifest.json" >/dev/null
printf 'Configuration and ACA manifest validated (%s).\n' "$(aca --version | tr -d '\r\n')"
for tool in az curl timeout openssl; do command -v "$tool" >/dev/null || fail "Required tool missing: $tool"; done
stage="context"
subscription="${subscription:-$(az account show --query id -o tsv | tr -d '\r\n')}"
group="$(az group show --subscription "$subscription" -n "$resource_group" -o json)"
region="${region:-$(jq -er '.location | strings | select(length > 0)' <<<"$group" | tr -d '\r\n')}"
sn="${DEPLOYMENT_SN:-}"
sn="$(printf '%s' "$sn" | tr -d '\r\n')"
if [[ -z "$sandbox_group" || (-z "$registry" && -z "${ACR_NAME:-}") || (-z "$identity" && -z "${IDENTITY_NAME:-}") ]]; then
  sn="${sn:-$(jq -er '.tags.deploymentSN | strings | select(test("^[a-zA-Z0-9-]+$"))' <<<"$group" | tr -d '\r\n')}"
fi
sandbox_group="${sandbox_group:-sandbox-group-agenthost-$sn}"
if [[ -z "$registry" ]]; then
  registry_name="$(printf '%s' "${ACR_NAME:-acragenthost$sn}" | tr -d '\r\n')"
  registry="$(az acr show --subscription "$subscription" -g "$resource_group" -n "$registry_name" --query loginServer -o tsv | tr -d '\r\n')"
fi
if [[ -z "$identity" ]]; then
  identity_name="$(printf '%s' "${IDENTITY_NAME:-id-agenthost-$sn}" | tr -d '\r\n')"
  identity="$(az identity show --subscription "$subscription" -g "$resource_group" -n "$identity_name" --query id -o tsv | tr -d '\r\n')"
fi
[[ "$registry" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || fail "--registry must be a login-server hostname"
# Match ARM IDs case-insensitively without changing the value sent to Azure.
identity_pattern='^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft[.]managedidentity/userassignedidentities/[^/]+$'
[[ "$identity" == system || "${identity,,}" =~ $identity_pattern ]] ||
  fail "--registry-identity must be system or a user-assigned identity ARM resource ID"
group_id="/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.App/sandboxGroups/$sandbox_group"
group_region="$(az resource show --ids "$group_id" --query location -o tsv | tr -d '\r\n')"
[[ "${group_region,,}" == "${region,,}" ]] || fail "Existing SandboxGroup region differs from the configured deployment region"
aca_call() {
  # Pin every call to the resolved group/scope and bound waits instead of relying on ambient defaults.
  timeout "$operation_timeout" aca "$@" --subscription "$subscription" --resource-group "$resource_group" \
    --group "$sandbox_group" --region "$region" -o json
}
single() {
  jq -e 'if type == "array" then
      if length == 1 then .[0] else error("Expected exactly one resource") end
      elif type == "object" then . else error("Expected a resource object") end' "$1"
}
record() {
  jq "$@" "$output" >"$tmp/inventory.json"
  mv -- "$tmp/inventory.json" "$output"
}
exec_checked() {
  local id="$1" command="$2" rc
  # exec streams guest output even with -o json and propagates the guest's exit status.
  if aca_call sandbox exec --id "$id" -c "$command" >"$tmp/response.json"; then
    return 0
  else
    rc=$?
    fail "Guest command failed at $stage for $active_role (exit $rc); inspect the guest securely"
  fi
}
stage="network"
timeout "$operation_timeout" aca sandboxgroup get --name "$sandbox_group" --subscription "$subscription" \
  --resource-group "$resource_group" --region "$region" -o json >"$tmp/response.json" ||
  fail "Cannot read existing SandboxGroup VNet connections"
jq -e --arg id "$group_id" '
  ((.id // "" | ascii_downcase)==($id|ascii_downcase)) and
  (.vnetConnections | type=="array") and
  all(.vnetConnections[]; (.name | type=="string" and length>0))
' "$tmp/response.json" >/dev/null || fail "Invalid SandboxGroup VNet connection response"
if [[ -z "$vnet" ]]; then
  connection_count="$(jq -r '.vnetConnections | length' "$tmp/response.json" | tr -d '\r\n')"
  case "$connection_count" in
    0) ;;
    1) vnet="$(jq -er '.vnetConnections[0].name' "$tmp/response.json" | tr -d '\r\n')" ;;
    *) fail "Multiple group VNet connections; select one with CUSTOMER_VNET_CONNECTION_NAME or --vnet-connection" ;;
  esac
fi
if [[ -n "$vnet" ]]; then
  jq -e --arg name "$vnet" '
    [.vnetConnections[] | select((.name|ascii_downcase)==($name|ascii_downcase))] |
    length==1 and .[0].properties.provisioningState=="Succeeded"
  ' "$tmp/response.json" >/dev/null ||
    fail "Selected VNet connection is missing, ambiguous or not Succeeded; complete Module-04 networking first"
  vnet="$(jq -er --arg name "$vnet" '.vnetConnections[] |
    select((.name|ascii_downcase)==($name|ascii_downcase)) | .name' "$tmp/response.json" | tr -d '\r\n')"
  printf 'Verified existing VNet connection: %s (all five Agents).\n' "$vnet"
else
  storage_id="${container_id%/blobServices/default/containers/data}"
  az resource show --ids "$storage_id" --api-version 2023-01-01 -o json >"$tmp/response.json" ||
    fail "Cannot read Blob storage network access settings"
  jq -e '.properties.publicNetworkAccess=="Enabled" and .properties.networkAcls.defaultAction=="Allow"' \
    "$tmp/response.json" >/dev/null ||
    fail "Blob storage is private, restricted or its network settings are unknown; configure a ready Module-04 VNet connection"
  printf 'No group VNet connection; verified Blob storage allows public network access.\n'
fi
deployment_id="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 | tr -d '\r\n')"
mkdir -p -- "$(dirname -- "$output")"
jq -n --arg deployment "$deployment_id" --arg sub "$subscription" --arg rg "$resource_group" \
  --arg group "$sandbox_group" --arg region "$region" --arg vnet "$vnet" \
  '{deployment_id:$deployment,status:"creating",subscription:$sub,resource_group:$rg,
      sandbox_group:$group,region:$region,vnet_connection:(if $vnet=="" then null else $vnet end),agents:
      (["chat","orchestrator","data-processing","rag","sql"] | map({key:.,value:{status:"pending"}}) | from_entries)}' >"$output"
recorded=true
printf 'Target: %s / %s / %s (%s)\nDeployment: %s\n' "$subscription" "$resource_group" "$sandbox_group" "$region" "$deployment_id"

stage="agent-identity"
# Sandbox identities are inherited from the group; --identity on disk import only authorizes ACR.
agent_identity="$(SUBSCRIPTION_ID="$subscription" RESOURCE_GROUP="$resource_group" DEPLOYMENT_SN="$sn" \
  bash "$root/common/resolve-identity.sh")"
agent_identity_id="$(jq -er '.AGENT_IDENTITY_RESOURCE_ID' <<<"$agent_identity" | tr -d '\r\n')"
agent_client_id="$(jq -er '.AGENT_IDENTITY_CLIENT_ID' <<<"$agent_identity" | tr -d '\r\n')"
agent_tenant_id="$(jq -er '.AZURE_TENANT_ID' <<<"$agent_identity" | tr -d '\r\n')"
jq -e --arg client "$agent_client_id" --arg tenant "$agent_tenant_id" '
  all(.[]; ((.AZURE_CLIENT_ID // $client)==$client) and ((.AZURE_TENANT_ID // $tenant)==$tenant))
' "$config" >/dev/null || fail "Runtime UAMI differs from the selected Module-01 UAMI"
az resource show --ids "$group_id" --query identity -o json >"$tmp/response.json"
if ! jq -e --arg id "$agent_identity_id" '
  any((.userAssignedIdentities // {} | keys)[]; ascii_downcase==($id|ascii_downcase))
' "$tmp/response.json" >/dev/null; then
  # This is additive: never replace other identities already used by the shared SandboxGroup.
  aca_call sandboxgroup identity assign --user-assigned "$agent_identity_id" >"$tmp/response.json"
  az resource show --ids "$group_id" --query identity -o json >"$tmp/response.json"
  jq -e --arg id "$agent_identity_id" '
    any((.userAssignedIdentities // {} | keys)[]; ascii_downcase==($id|ascii_downcase))
  ' "$tmp/response.json" >/dev/null || fail "Module-01 UAMI was not assigned to the SandboxGroup"
fi

# -- Verify or create the group-level Blob volume ----------------------------
stage="volume"
volume_identity="$(printf '%s' "${KB_VOLUME_IDENTITY:-$identity}" | tr -d '\r\n')"
identity_kind=UserAssigned
identity_args=(--identity-resource-id "$volume_identity")
if [[ "$volume_identity" == system ]]; then
  identity_kind=SystemAssigned
  identity_args=()
else
  [[ "${volume_identity,,}" =~ $identity_pattern ]] ||
    fail "KB_VOLUME_IDENTITY must be system or an existing group user-assigned identity ARM ID"
fi
record --arg name "$volume_name" --arg container "$container_id" --arg kind "$identity_kind" \
  --arg identity "$volume_identity" \
  '.volume={name:$name,type:"AzureBlobByo",storage_container_id:$container,identity_kind:$kind,identity:$identity,mount_path:"/kb-data",read_only:true}'
storage_id="${container_id%/blobServices/default/containers/data}"
storage_url="$(az resource show --ids "$storage_id" --query properties.primaryEndpoints.blob -o tsv | tr -d '\r\n')"
configured_url="$(jq -er '.chat.AZURE_STORAGE_ACCOUNT_URL' "$config" | tr -d '\r\n')"
[[ "${storage_url%/}" == "${configured_url%/}" ]] ||
  fail "KB_STORAGE_CONTAINER_ID does not match the configured AZURE_STORAGE_ACCOUNT_URL"
az resource show --ids "$group_id" --query identity -o json >"$tmp/response.json"
jq -e --arg identity "$volume_identity" '
    if $identity=="system" then (.principalId | type=="string" and length>0)
    else any((.userAssignedIdentities // {} | keys)[]; ascii_downcase==($identity|ascii_downcase)) end
    ' "$tmp/response.json" >/dev/null ||
  fail "The selected Blob volume managed identity is not assigned to the existing SandboxGroup"
# Listing must succeed: authentication/authorization failures must never be treated as absence.
aca_call sandboxgroup volume list >"$tmp/response.json"
exists="$(jq -r --arg name "$volume_name" '
    if type!="array" then error("Expected volume list") else
    any(.[]; (.volumeName // .name)==$name) end' "$tmp/response.json" | tr -d '\r\n')"
if [[ "$exists" == false ]]; then
  aca_call sandboxgroup volume create --name "$volume_name" --type AzureBlobByo \
    --storage-container-id "$container_id" --identity-kind "$identity_kind" \
    "${identity_args[@]}" >"$tmp/response.json"
fi
aca_call sandboxgroup volume get --name "$volume_name" >"$tmp/response.json"
# Never repoint a shared volume silently: its container and managed identity must both match.
single "$tmp/response.json" | jq -e --arg name "$volume_name" --arg container "$container_id" \
  --arg kind "$identity_kind" --arg identity "$volume_identity" '
    (.volumeName // .name)==$name and .type=="AzureBlobByo" and
    ((.storageContainerResourceId // "" | ascii_downcase)==($container|ascii_downcase)) and
    .auth.kind=="ManagedIdentity" and .auth.identity.kind==$kind and
    (if $kind=="UserAssigned" then
        (.auth.identity.resourceId // "" | ascii_downcase)==($identity|ascii_downcase)
     else (.auth.identity.resourceId // "")=="" end)' >/dev/null ||
  fail "Existing volume differs from the requested container or identity; choose another KB_VOLUME_NAME, do not delete shared data"

# -- Import all five images and create the Sandboxes -------------------------
stage="image-import"
for active_role in "${roles[@]}"; do
  image="$registry/studio-$active_role:$tag"
  disk_name="studio-$active_role-$deployment_id"
  record --arg role "$active_role" --arg image "$image" --arg name "$disk_name" \
    '.agents[$role] += {image:$image,disk_name:$name,status:"importing"}'
  printf 'Importing %s...\n' "$active_role"
  # Sandboxes boot from disk images; the group identity authorizes importing each OCI image from ACR.
  aca_call sandboxgroup disk create --image "$image" --name "$disk_name" --identity "$identity" \
    --label "deployment=$deployment_id" --label "role=$active_role" \
    --wait-timeout "$operation_timeout" >"$tmp/response.json"
  disk_id="$(single "$tmp/response.json" | jq -er '.id | strings | select(length > 0)' | tr -d '\r\n')"
  record --arg role "$active_role" --arg id "$disk_id" '.agents[$role] += {disk_id:$id,status:"imported"}'
done
stage="sandbox-create"
for active_role in "${roles[@]}"; do
  disk_id="$(jq -er --arg role "$active_role" '.agents[$role].disk_id' "$output" | tr -d '\r\n')"
  manifest "$active_role" "$disk_id"
  aca sandbox validate --file "$tmp/manifest.json" >/dev/null
  aca_call sandbox apply --file "$tmp/manifest.json" --wait-timeout "$operation_timeout" >"$tmp/response.json"
  # Preview apply can print "Created sandbox: ..." even with -o json. Read persisted state instead.
  sandbox_id=""
  for attempt in {1..6}; do
    aca_call sandbox list --selector "role=$active_role" >"$tmp/response.json" ||
      fail "Cannot discover the created sandbox; preserve the inventory and inspect its role and source disk ID"
    # Older deployments can share this role, but each run imports a distinct disk per role.
    jq -e --arg disk "$disk_id" '
      if type!="array" then error("Expected sandbox list")
      else map(select(.sourcesRef.diskImage.id==$disk)) end |
      if length>1 then error("Multiple sandboxes use the imported disk") else . end
    ' "$tmp/response.json" >"$tmp/probe.json" ||
      fail "Invalid sandbox list or ambiguous source disk match; no further sandboxes will be created"
    if jq -e 'length==1' "$tmp/probe.json" >/dev/null; then
      sandbox_id="$(jq -er --arg role "$active_role" --arg deployment "$deployment_id" '
        .[0] | select(.labels=={role:$role,deployment:$deployment}) |
        .id | strings | select(length>0)
      ' "$tmp/probe.json" | tr -d '\r\n')" ||
        fail "Created sandbox ID, labels or source disk did not match; inspect the deployment before retrying"
      break
    fi
    if ((attempt < 6)); then sleep 5; fi
  done
  [[ -n "$sandbox_id" ]] ||
    fail "Created sandbox was not visible after bounded discovery; do not assume creation failed or delete the inventory"
  record --arg role "$active_role" --arg id "$sandbox_id" '.agents[$role] += {sandbox_id:$id,status:"created"}'
  # Workshop ingress is public to anyone with the URL; application API keys remain required.
  aca_call sandbox port add --id "$sandbox_id" --port 8080 --anonymous >"$tmp/response.json"
  url="$(single "$tmp/response.json" | jq -er '.url | strings |
        select(test("^https://[a-zA-Z0-9.-]+(:[0-9]+)?/?$")) | rtrimstr("/")' | tr -d '\r\n')"
  record --arg role "$active_role" --arg url "$url" '.agents[$role].url=$url'
done

# -- Mount data only for Chat and Data Processing ----------------------------
# Read-only limits /kb-data writes, not Blob SDK uploads, which use their own identity/network access.
stage="mount"
for active_role in "${mount_roles[@]}"; do
  sandbox_id="$(jq -er --arg role "$active_role" '.agents[$role].sandbox_id' "$output" | tr -d '\r\n')"
  aca_call sandbox mount --id "$sandbox_id" --volume "$volume_name" --path /kb-data \
    --readonly >"$tmp/response.json"
  exec_checked "$sandbox_id" "python -c '$mount_probe'"
  record --arg role "$active_role" --arg volume "$volume_name" \
    '.agents[$role].mount={volume:$volume,path:"/kb-data",read_only:true,verified_uid:10001}'
done

# -- Upload protected runtime configuration ---------------------------------
stage="configuration"
for active_role in "${roles[@]}"; do
  sandbox_id="$(jq -er --arg role "$active_role" '.agents[$role].sandbox_id' "$output" | tr -d '\r\n')"
  # Use actual ingress URLs, not guessed hostnames, for discovery and downstream A2A requests.
  jq --arg role "$active_role" --slurpfile inventory "$output" \
    --arg client "$agent_client_id" --arg tenant "$agent_tenant_id" '
      $inventory[0].agents as $a | .[$role] + {
        AZURE_CLIENT_ID:$client,AZURE_TENANT_ID:$tenant,
        A2A_PUBLIC_URL:$a[$role].url,ORCHESTRATOR_URL:$a.orchestrator.url,
        DATA_PROCESSING_URL:$a["data-processing"].url,RAG_URL:$a.rag.url,SQL_URL:$a.sql.url}
    ' "$config" >"$tmp/runtime.json"
  exec_checked "$sandbox_id" 'install -d -m 700 -o 10001 -g 10001 /app/.local'
  # fs write creates root-owned files; the guest user must copy, not chmod/chown, the upload.
  aca_call sandbox fs write --id "$sandbox_id" --path /app/.local/studio-runtime.pending \
    --file "$tmp/runtime.json" >"$tmp/response.json"
  exec_checked "$sandbox_id" 'set -eu
owned=$(mktemp /app/.local/studio-runtime.XXXXXX)
trap "rm -f -- \"$owned\"" EXIT
install -m 600 -- /app/.local/studio-runtime.pending "$owned"
test "$(stat -c "%u:%g:%a" "$owned")" = 10001:10001:600
mv -f -- "$owned" /app/.local/studio-runtime.json
rm -- /app/.local/studio-runtime.pending'
  record --arg role "$active_role" '.agents[$role].status="configured"'
done

# These are application commands in the guest, not a local provisioning SDK.
load_config='import os; from pathlib import Path; from shared.sandbox_bootstrap import load_environment; os.environ.update(load_environment(Path("/app/.local/studio-runtime.json"))); '
stage="identity-check"
# Acquiring a token in each guest proves the platform exposes the selected UAMI, not merely ACR access.
for active_role in "${roles[@]}"; do
  sandbox_id="$(jq -er --arg role "$active_role" '.agents[$role].sandbox_id' "$output" | tr -d '\r\n')"
  exec_checked "$sandbox_id" "cd /app && python -c '${load_config}from azure.identity import ManagedIdentityCredential; credential=ManagedIdentityCredential(client_id=os.environ[\"AZURE_CLIENT_ID\"]); credential.get_token(\"https://cognitiveservices.azure.com/.default\"); credential.close()'"
done
if $migrate; then
  # Run shared-schema migration once, from Orchestrator, rather than racing all five guests.
  stage="database-migration" active_role="orchestrator"
  sandbox_id="$(jq -er '.agents.orchestrator.sandbox_id' "$output" | tr -d '\r\n')"
  if [[ "$(jq -r '.orchestrator.DB_AUTH_MODE // "password"' "$config" | tr -d '\r\n')" == entra ]]; then
    exec_checked "$sandbox_id" 'cd /app && python -m shared.database_bootstrap --config /app/.local/studio-runtime.json --migrate'
  else
    exec_checked "$sandbox_id" "cd /app && python -c '${load_config}from shared.database import migrate; migrate()'"
  fi
fi
stage="database-check"
# Chat delegates to Orchestrator; only the four backend roles need direct database/schema checks.
for active_role in orchestrator data-processing rag sql; do
  sandbox_id="$(jq -er --arg role "$active_role" '.agents[$role].sandbox_id' "$output" | tr -d '\r\n')"
  if [[ "$(jq -r --arg role "$active_role" '.[$role].DB_AUTH_MODE // "password"' "$config" | tr -d '\r\n')" == entra ]]; then
    # Verify actual UAMI SQL permissions, not just Azure role-assignment existence.
    exec_checked "$sandbox_id" 'cd /app && python -m shared.database_bootstrap --config /app/.local/studio-runtime.json'
  else
    exec_checked "$sandbox_id" "cd /app && python -c '${load_config}import psycopg; from shared.config import Settings; from shared.database import connection_info; c=psycopg.connect(connection_info(Settings()), connect_timeout=10); c.execute(\"SELECT id FROM workspaces LIMIT 0\"); c.execute(\"SELECT NULL::vector\"); c.close()'"
  fi
done
stage="activation"
# Release all startup gates only after mounts, runtime configuration and database checks succeed.
for active_role in "${roles[@]}"; do
  sandbox_id="$(jq -er --arg role "$active_role" '.agents[$role].sandbox_id' "$output" | tr -d '\r\n')"
  exec_checked "$sandbox_id" 'touch /app/.local/studio-start && chmod 600 /app/.local/studio-start'
  record --arg role "$active_role" '.agents[$role].status="starting"'
done

stage="health"
active_role=""
# Header files keep API keys out of curl's literal command-line arguments.
jq -r '"Authorization: Bearer " + .chat.A2A_API_KEY' "$config" >"$tmp/peer-header"
deadline=$((SECONDS + health_timeout))
# Share one deadline across all roles; a slow endpoint must not multiply the overall timeout.
while ((SECONDS < deadline)); do
  all_ready=true
  for role in "${roles[@]}"; do
    previous_status="$(jq -r --arg role "$role" '.agents[$role].status' "$output" | tr -d '\r\n')"
    url="$(jq -er --arg role "$role" '.agents[$role].url' "$output" | tr -d '\r\n')"
    budget=$((deadline - SECONDS))
    ((budget > 0)) || {
      all_ready=false
      break
    }
    ((budget <= 5)) || budget=5
    if curl --silent --fail --proto '=https' --connect-timeout "$budget" --max-time "$budget" \
      "$url/health" -o "$tmp/health.json" &&
      jq -e '.status == "ok"' "$tmp/health.json" >/dev/null; then
      budget=$((deadline - SECONDS))
      ((budget > 0)) || {
        all_ready=false
        break
      }
      ((budget <= 5)) || budget=5
      if curl --silent --fail --proto '=https' --connect-timeout "$budget" --max-time "$budget" \
        --header "@$tmp/peer-header" "$url/.well-known/agent-card.json" -o "$tmp/card.json" &&
        jq -e --arg role "$role" --arg url "$url/a2a" '
                  .name == ("studio-" + $role) and .capabilities.streaming == true
                  and any(.supportedInterfaces[]?;
                    .url == $url and .protocolBinding == "JSONRPC" and .protocolVersion == "1.0")
                ' "$tmp/card.json" >/dev/null; then
        if [[ "$previous_status" != ready ]]; then
          record --arg role "$role" '.agents[$role].status="ready"'
          printf 'READY %s %s\n' "$role" "$url"
        fi
        continue
      fi
    fi
    if [[ "$previous_status" == ready ]]; then
      record --arg role "$role" '.agents[$role].status="starting"'
    fi
    all_ready=false
  done
  $all_ready && break
  ((SECONDS >= deadline)) || sleep 1
done
if ! jq -e 'all(.agents[]; .status == "ready")' "$output" >/dev/null; then
  record '.agents |= with_entries(if .value.status != "ready" then .value.status="timeout" else . end)'
  fail "Readiness deadline exceeded; pending Agents did not pass process and authenticated-card checks"
fi

stage="a2a-smoke"
# Exercise keyless browser access and authenticated Chat -> Orchestrator collaboration.
active_role="chat"
url="$(jq -er '.agents.chat.url' "$output" | tr -d '\r\n')"
curl --silent --show-error --fail --proto '=https' --connect-timeout 10 --max-time 60 \
  "$url/api/workspaces" -o "$tmp/probe.json"
jq -e 'type == "array"' "$tmp/probe.json" >/dev/null || fail "Chat-to-Orchestrator workspace read returned an unexpected response"
active_role=""
record --arg identity "$agent_identity_id" --arg auth "$(jq -r '.orchestrator.DB_AUTH_MODE // "password"' "$config" | tr -d '\r\n')" \
  '.status="ready" | .agent_identity=$identity | .checks={managed_identity:true,kb_mounts:true,process_health:true,authenticated_cards:true,database_schema:true,database_read_write:($auth=="entra"),chat_a2a_read:true}'
printf '\nAll five Agents are ready; database/schema and Chat -> A2A -> Orchestrator read passed.\n'
printf 'Foundry generation/embeddings, Blob upload and worker workflows still need end-to-end acceptance.\n'
