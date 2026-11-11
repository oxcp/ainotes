#!/usr/bin/env bash
# deploy-database.sh -- Module 6: deploy the selected PostgreSQL-compatible database.
#
# Reuses the Module 1 resource group and location:
#   1. Validate provider, credentials and sizing
#   2. Prepare protected ARM parameters and firewall rules
#   3. Validate the Bicep deployment, then provision
#   4. Save nonsecret connection settings for the next stage
#
# Usage: bash deploy-database.sh [--provider horizondb|postgresql]
# Env overrides: DB_PROVIDER, DB_PASSWORD_FILE, DB_RESOURCE_NAME and others in --help.
# Prerequisites: Module 1 deployed; az, jq and mktemp installed.

set +x
set -euo pipefail
umask 077

# -- Helpers and command-line options ----------------------------------------
usage() {
  cat <<'HELP'
Usage: bash deploy-database.sh [options]
  --provider NAME            DB_PROVIDER: horizondb (default) or postgresql; no fallback
  --subscription ID          SUBSCRIPTION_ID; otherwise current az account
  --resource-group NAME      Existing Module-01 RG (RESOURCE_GROUP or rg-agenthost-workshop)
  --location REGION          DB_LOCATION, then LOCATION; otherwise existing RG location
  --resource-name NAME       DB_RESOURCE_NAME; otherwise hdb-agenthost-<SN> or pg-agenthost-<SN>
  --cluster-name NAME        Compatibility alias for --resource-name
  --admin-username NAME      DB_ADMIN_USERNAME, legacy DB_USERNAME, or studioadmin
  --identity-resource-id ID  AGENT_IDENTITY_RESOURCE_ID; Module-01 UAMI (enables Entra SQL admin)
  --reuse-entra-admin        Optional existing-only guard; default HorizonDB flow creates/verifies admin automatically
  --vcores NUMBER            DB_VCORES or 2 (HorizonDB only)
  --sku-name NAME            DB_SKU_NAME or Standard_D2ds_v5 (PostgreSQL GeneralPurpose)
  --storage-size-gb NUMBER   DB_STORAGE_SIZE_GB or 32 (PostgreSQL, 32-65536)
  --password-file FILE       Overrides DB_PASSWORD; otherwise DB_PASSWORD_FILE
                            or .local/database-password (no default password)
  --firewall-rules-file FILE DB_FIREWALL_RULES_FILE; otherwise public IPv4 0.0.0.0-255.255.255.255
  --output FILE              DB_OUTPUT or .local/database-deployment.json
  --help
Precedence: explicit flags > environment > defaults. SN: DEPLOYMENT_SN or RG deploymentSN tag.
Running this script creates billable resources after mandatory ARM validation.
Never creates a resource group. Password uses a protected temporary file, never a literal argument.
WARNING: the default firewall exposes the database to all IPv4 addresses. TLS/authentication remain required.
PostgreSQL Flexible Server uses PG17, the existing postgres database and the vector allowlist.
HorizonDB requires preview access/region capacity; failure never switches provider or region.
With a UAMI, PostgreSQL ARM creates the Entra admin; HorizonDB REST creates/verifies it after ARM succeeds.
The guest database_bootstrap helper still must migrate/grant/check SQL access before Agents are ready.
HELP
}
fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
# Subshell helpers preserve the former scripts' variable, exit and cleanup isolation.
ensure_horizon_admin() (
  set +x
  set -euo pipefail
  trap - EXIT INT TERM
  fail() { printf 'Error [horizondb-admin]: %s\n' "$*" >&2; exit 1; }
  [[ $# == 5 || ( $# == 6 && "$6" == --existing-only ) ]] ||
    fail "Usage: ensure_horizon_admin CLUSTER_ID PRINCIPAL_ID NAME TENANT_ID REGION [--existing-only]"
  cluster_id="$1" principal="$2" name="$3" tenant="$4" region="$5"
  existing_only="${6:-}"
  cluster="$(az resource show --ids "$cluster_id" --api-version 2026-05-01-preview -o json)" ||
    fail "Cannot read HorizonDB cluster"
  jq -e --arg id "$cluster_id" --arg tenant "$tenant" --arg region "$region" '
    (.id|ascii_downcase)==($id|ascii_downcase) and .properties.provisioningState=="Succeeded" and
    (.location|ascii_downcase)==($region|ascii_downcase) and
    .properties.authConfig.entraIdAuth=="Enabled" and
    (.properties.authConfig.tenantId|ascii_downcase)==($tenant|ascii_downcase)
  ' <<<"$cluster" >/dev/null || fail "Cluster ID, state, region or Entra tenant mismatch"

  read_admin() {
    local response
    response="$(az rest --method get --url "$cluster_id/administrators?api-version=2026-05-01-preview" -o json)" ||
      fail "Cannot read HorizonDB administrators"
    admin_state="$(jq -er --arg principal "$principal" --arg name "$name" --arg tenant "$tenant" '
      if (.value|type)!="array" or ((.nextLink // "")!="") then
        error("Incomplete administrator list; refusing to infer absence")
      else
        [.value[] | select((.name|ascii_downcase)==($principal|ascii_downcase) or
          (.properties.objectId|ascii_downcase)==($principal|ascii_downcase) or .properties.principalName==$name)] as $found |
        if ($found|length)==0 then "absent"
        elif ($found|length)==1 and ($found[0] |
          (.name|ascii_downcase)==($principal|ascii_downcase) and
          (.properties.objectId|ascii_downcase)==($principal|ascii_downcase) and
          .properties.principalName==$name and .properties.principalType=="ServicePrincipal" and
          (.properties.tenantId|ascii_downcase)==($tenant|ascii_downcase)) then "matched"
        else error("Conflicting administrator identity; refusing to overwrite") end
      end' <<<"$response" | tr -d '\r\n')" || fail "Cannot verify HorizonDB administrator identity"
  }
  read_admin
  if [[ "$admin_state" == matched ]]; then
    printf 'Verified existing HorizonDB Entra administrator: %s\n' "$name"
    exit 0
  fi
  [[ -z "$existing_only" ]] || fail "Requested existing administrator is missing"
  body="$(jq -n --arg name "$name" --arg tenant "$tenant" \
    '{properties:{principalName:$name,principalType:"ServicePrincipal",tenantId:$tenant}}')"
  printf 'Creating HorizonDB Entra administrator: %s\n' "$name"
  # The preview PUT may return no body; verify persisted identity independently.
  az rest --method put --url "$cluster_id/administrators/$principal?api-version=2026-05-01-preview" \
    --body "$body" --output none || fail "Administrator PUT failed; no success inventory will be published"
  for attempt in 1 2 3 4 5 6; do
    read_admin
    if [[ "$admin_state" == matched ]]; then
      printf 'Verified created HorizonDB Entra administrator: %s\n' "$name"
      exit 0
    fi
    if ((attempt < 6)); then sleep 5; fi
  done
  fail "Administrator PUT returned successfully but the matching identity was not visible after bounded verification"
)

configure_horizon_cluster() (
  set +x
  set -euo pipefail
  trap - EXIT INT TERM
  fail() { printf 'Error [horizondb-config]: %s\n' "$*" >&2; exit 1; }
  [[ $# == 6 ]] || fail "Usage: configure_horizon_cluster CLUSTER_ID REGION ADMIN CORES TENANT ENTRA_ENABLED"
  id="$1" region="$2" admin="$3" cores="$4" tenant="$5" entra="$6"
  [[ "$entra" == Enabled || "$entra" == Disabled ]] || fail "Invalid Entra authentication mode"
  parameter_group="${id%/clusters/*}/parameterGroups/${id##*/}-vector"
  read_cluster() {
    cluster="$(az resource show --ids "$id" --api-version 2026-05-01-preview -o json)" ||
      fail "Cannot read HorizonDB cluster"
    jq -e --arg id "$id" --arg region "$region" --arg admin "$admin" --argjson cores "$cores" '
      (.id|ascii_downcase)==($id|ascii_downcase) and (.location|ascii_downcase)==($region|ascii_downcase) and
      .properties.version=="17" and .properties.administratorLogin==$admin and
      .properties.vCores==$cores and .properties.replicaCount==1 and .properties.zonePlacementPolicy=="BestEffort"
    ' <<<"$cluster" >/dev/null || fail "Cluster identity, region, administrator, version or sizing mismatch"
    state="$(jq -er '.properties.provisioningState | strings | select(length>0)' <<<"$cluster" | tr -d '\r\n')" ||
      fail "Cluster provisioning state missing"
    case "$state" in Failed | Canceled | Deleting) fail "Cluster is in terminal state $state" ;; esac
  }
  configured() {
    jq -e --arg group "$parameter_group" --arg tenant "$tenant" --arg entra "$entra" '
      .properties.provisioningState=="Succeeded" and
      ((.properties.parameterGroup.id // "")|ascii_downcase)==($group|ascii_downcase) and
      .properties.parameterGroup.syncStatus=="InSync" and .properties.parameterGroup.isUsingLatestConfig==true and
      .properties.authConfig.passwordAuth=="Enabled" and .properties.authConfig.entraIdAuth==$entra and
      ($entra=="Disabled" or ((.properties.authConfig.tenantId // "")|ascii_downcase)==($tenant|ascii_downcase))
    ' <<<"$cluster" >/dev/null
  }
  read_cluster
  if configured; then
    printf 'Verified HorizonDB parameter group and authentication settings; no cluster update required.\n'
    exit 0
  fi
  [[ "$state" == Succeeded ]] || fail "Cluster update is still in progress; wait before retrying"
  # Only mutable settings go through PATCH; creation-only fields and passwords are never replayed.
  body="$(jq -n --arg group "$parameter_group" --arg tenant "$tenant" --arg entra "$entra" '
    {properties:{parameterGroup:{id:$group,applyImmediately:true},
      authConfig:({passwordAuth:"Enabled",entraIdAuth:$entra} +
        (if $entra=="Enabled" then {tenantId:$tenant} else {} end))}}')"
  printf 'Updating HorizonDB parameter-group association and authentication via PATCH.\n'
  az rest --method patch --url "$id?api-version=2026-05-01-preview" --body "$body" --output none ||
    fail "Cluster configuration PATCH failed"
  for attempt in {1..30}; do
    read_cluster
    if configured; then
      printf 'Verified HorizonDB parameter group is InSync and authentication settings match.\n'
      exit 0
    fi
    if ((attempt < 30)); then sleep 10; fi
  done
  fail "Cluster configuration was not confirmed after bounded verification; success inventory was not published"
)
# -- Configuration ----------------------------------------------------------
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
subscription="${SUBSCRIPTION_ID:-}"
resource_group="${RESOURCE_GROUP:-rg-agenthost-workshop}"
location="${DB_LOCATION:-${LOCATION:-}}"
provider="${DB_PROVIDER:-horizondb}"
cluster="${DB_RESOURCE_NAME:-}"
admin="${DB_ADMIN_USERNAME:-${DB_USERNAME:-studioadmin}}"
identity_id="${AGENT_IDENTITY_RESOURCE_ID:-}"
identity_principal="" identity_client="" identity_name="" identity_tenant="" auth_mode="password"
reuse_admin="${DB_REUSE_ENTRA_ADMIN:-false}"
vcores="${DB_VCORES:-2}"
sku="${DB_SKU_NAME:-Standard_D2ds_v5}"
storage="${DB_STORAGE_SIZE_GB:-32}"
password_file="${DB_PASSWORD_FILE:-$root/.local/database-password}"
password_from_env="${DB_PASSWORD:-}"
# Retain the value only in this shell, not in the environment inherited by child processes.
unset DB_PASSWORD
firewall_file="${DB_FIREWALL_RULES_FILE:-}"
vcores_explicit=false sizing_explicit=false
output="${DB_OUTPUT:-$root/.local/database-deployment.json}"
while (($#)); do
  case "$1" in
    --reuse-entra-admin)
      reuse_admin=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    --provider | --subscription | --resource-group | --location | --resource-name | --cluster-name | --admin-username | --identity-resource-id | --vcores | --sku-name | --storage-size-gb | --password-file | --firewall-rules-file | --output)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || fail "Missing value for $1"
      case "$1" in
        --subscription) subscription="$2" ;; --location) location="$2" ;;
        --provider) provider="$2" ;;
        --identity-resource-id) identity_id="$2" ;;
        --resource-group) resource_group="$2" ;; --resource-name | --cluster-name) cluster="$2" ;;
        --admin-username) admin="$2" ;; --vcores)
          vcores="$2"
          vcores_explicit=true
          ;;
        --sku-name)
          sku="$2"
          sizing_explicit=true
          ;;
        --storage-size-gb)
          storage="$2"
          sizing_explicit=true
          ;;
        --password-file)
          password_file="$2"
          password_from_env=""
          ;;
        --firewall-rules-file) firewall_file="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2
      ;;
    *) fail "Unknown option: $1" ;;
  esac
done
# Normalize CLI metadata, never passwords or file contents.
for key in subscription resource_group location provider cluster admin identity_id vcores sku storage; do
  printf -v "$key" '%s' "$(printf '%s' "${!key}" | tr -d '\r\n')"
done
# -- Validate provider, credentials and sizing -------------------------------
case "$provider" in
  horizondb)
    prefix=hdb
    resource_type="Microsoft.HorizonDb/clusters"
    ;;
  postgresql)
    prefix=pg
    resource_type="Microsoft.DBforPostgreSQL/flexibleServers"
    ;;
  *) fail "DB_PROVIDER must be horizondb or postgresql" ;;
esac
[[ "$reuse_admin" == true || "$reuse_admin" == false ]] || fail "DB_REUSE_ENTRA_ADMIN must be true or false"
if [[ "$reuse_admin" == true ]]; then
  [[ "$provider" == horizondb && -n "$identity_id" ]] ||
    fail "--reuse-entra-admin requires HorizonDB and AGENT_IDENTITY_RESOURCE_ID"
fi
template="$root/bicep/database.bicep"
for tool in az jq mktemp; do command -v "$tool" >/dev/null || fail "Required tool missing: $tool"; done
[[ -n "$password_from_env" || -f "$password_file" ]] || fail "Set DB_PASSWORD or provide a protected password file"
[[ "$admin" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,62}$ ]] || fail "Invalid administrator name"
if [[ "$provider" == postgresql ]]; then
  ! $vcores_explicit || fail "--vcores is HorizonDB-only; use --sku-name for PostgreSQL"
  # Unused provider-specific inputs get neutral defaults; only SKU/storage reach PostgreSQL.
  vcores=2
  [[ "$sku" =~ ^Standard_[A-Za-z0-9_]+$ ]] || fail "Invalid PostgreSQL SKU name"
  [[ "$storage" =~ ^[0-9]{1,5}$ ]] || fail "Invalid PostgreSQL storage size"
  ((10#$storage >= 32 && 10#$storage <= 65536)) || fail "PostgreSQL storage must be 32-65536 GiB"
  case "${admin,,}" in azure_superuser | azure_pg_admin | admin | administrator | root | guest | public | pg_*)
    fail "Reserved PostgreSQL administrator name"
    ;;
  esac
else
  ! $sizing_explicit || fail "--sku-name and --storage-size-gb are PostgreSQL-only; use --vcores for HorizonDB"
  [[ "$vcores" =~ ^[0-9]+$ && ${#vcores} -le 2 ]] || fail "Invalid vCore count"
  ((10#$vcores >= 2 && 10#$vcores <= 96)) || fail "vCores must be between 2 and 96"
  storage=32
fi
[[ ! -e "$output" ]] || fail "Output already exists; preserve it and select a new --output"

# -- Prepare protected parameters and failure handling -----------------------
mkdir -p -- "$root/.local"
chmod 700 "$root/.local"
tmp="$(mktemp -d "$root/.local/database-deploy.XXXXXX")"
recorded=false
stage="validation"
cleanup() {
  local rc=$?
  trap - EXIT
  if ((rc != 0)); then
    printf 'Error: %s %s failed. No automatic rollback or provider fallback was performed.\n' "$provider" "$stage" >&2
    # Keep the attempted ARM resource ID even if provisioning or output validation fails.
    if $recorded; then
      jq --arg stage "$stage" '.status="failed" | .failed_stage=$stage' "$output" >"$tmp/status.json" &&
        mv -- "$tmp/status.json" "$output"
      printf 'Resource identity retained in %s\n' "$output" >&2
    fi
  fi
  # Temporary parameters and diagnostics may contain credentials; remove them on every exit.
  rm -f -- "$tmp/parameters.json" "$tmp/rules.json" "$tmp/result.json" "$tmp/status.json" "$tmp/password" "$tmp/diagnostics"
  rmdir -- "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n "$password_from_env" ]]; then
  printf '%s' "$password_from_env" >"$tmp/password"
  unset password_from_env
  password_file="$tmp/password"
fi
if [[ -n "$firewall_file" ]]; then
  [[ -f "$firewall_file" ]] || fail "Firewall rules file not found"
  cp -- "$firewall_file" "$tmp/rules.json"
else
  # Workshop convenience, not a production policy: this range admits every IPv4 client.
  printf '[{"name":"workshop-public","startIpAddress":"0.0.0.0","endIpAddress":"255.255.255.255"}]\n' >"$tmp/rules.json"
fi
# Validate octets, range ordering and unique names before submitting any firewall rules.
jq -e '
  def ipv4:
    type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")
    and (split(".") | all(.[]; tonumber <= 255));
  def ipnumber: split(".") | map(tonumber) | reduce .[] as $n (0; . * 256 + $n);
  type == "array" and all(.[];
    type == "object" and (keys | sort) == ["endIpAddress","name","startIpAddress"]
    and (.name | type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9-]{0,126}[a-zA-Z0-9]$"))
    and (.startIpAddress | ipv4) and (.endIpAddress | ipv4)
    and ((.startIpAddress | ipnumber) <= (.endIpAddress | ipnumber)))
  and ([.[].name] | length == (unique | length))
' "$tmp/rules.json" >/dev/null || fail "Invalid IPv4 firewall ranges"
if jq -e 'any(.[]; .startIpAddress=="0.0.0.0" and .endIpAddress=="255.255.255.255")' "$tmp/rules.json" >/dev/null; then
  printf 'WARNING: public database access allows ALL IPv4 addresses (0.0.0.0 - 255.255.255.255). Use only for the workshop; keep TLS and strong credentials.\n' >&2
fi

# -- Resolve the existing Module 1 deployment context -------------------------
subscription="${subscription:-$(az account show --query id -o tsv | tr -d '\r\n')}"
group="$(az group show --subscription "$subscription" -n "$resource_group" -o json)"
location="${location:-$(jq -er '.location | strings | select(length > 0)' <<<"$group" | tr -d '\r\n')}"
if [[ -z "$cluster" ]]; then
  sn="${DEPLOYMENT_SN:-$(jq -er '.tags.deploymentSN | strings | select(test("^[a-zA-Z0-9-]+$"))' <<<"$group" | tr -d '\r\n')}"
  sn="$(printf '%s' "$sn" | tr -d '\r\n')"
  cluster="$prefix-agenthost-$sn"
fi
[[ "$cluster" =~ ^[a-z][a-z0-9-]{1,53}[a-z0-9]$ ]] || fail "Cluster name must be 3-55 lowercase letters/digits/hyphens"
# Resolve the actual UAMI object ID, not its client ID: the provider administrator API keys on principalId.
# Always query ARM even when callers export IDs, so a stale/mismatched environment cannot grant another principal.
if [[ -n "$identity_id" ]]; then
  [[ "${identity_id,,}" =~ ^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft.managedidentity/userassignedidentities/[^/]+$ ]] ||
    fail "Identity must be a user-assigned managed identity ARM resource ID"
  identity="$(az identity show --ids "$identity_id" -o json)"
  identity_principal="$(jq -er '.principalId | strings | select(test("^[0-9a-fA-F-]{36}$"))' <<<"$identity" | tr -d '\r\n')"
  identity_client="$(jq -er '.clientId | strings | select(test("^[0-9a-fA-F-]{36}$"))' <<<"$identity" | tr -d '\r\n')"
  identity_tenant="$(jq -er '.tenantId | strings | select(test("^[0-9a-fA-F-]{36}$"))' <<<"$identity" | tr -d '\r\n')"
  identity_name="$(jq -er '.name | strings | select(length > 0 and utf8bytelength <= 63)' <<<"$identity" | tr -d '\r\n')"
  # PostgreSQL identifiers are limited to 63 bytes; reject rather than silently truncating the UAMI name.
  [[ "$identity_name" != "$admin" ]] || fail "UAMI name must differ from the password administrator"
  auth_mode="entra"
  printf 'Entra SQL administrator: %s (guest SQL grants/check still required).\n' "$identity_name"
fi
cluster_id="/subscriptions/$subscription/resourceGroups/$resource_group/providers/$resource_type/$cluster"
reuse_cluster=false
if [[ "$provider" == horizondb ]]; then
  clusters="$(az resource list --subscription "$subscription" --resource-group "$resource_group" \
    --resource-type Microsoft.HorizonDb/clusters -o json)" || fail "Cannot discover existing HorizonDB clusters"
  matches="$(jq -er --arg id "$cluster_id" '
    if type!="array" then error("Invalid resource list") else
      [.[] | select((.id|ascii_downcase)==($id|ascii_downcase))] | length end
    ' <<<"$clusters" | tr -d '\r\n')" || fail "Invalid HorizonDB discovery response"
  [[ "$matches" == 0 || "$matches" == 1 ]] || fail "Ambiguous HorizonDB resource identity"
  if [[ "$matches" == 1 ]]; then
    existing="$(az resource show --ids "$cluster_id" --api-version 2026-05-01-preview -o json)" ||
      fail "Cannot read existing HorizonDB cluster"
    jq -e --arg id "$cluster_id" --arg region "$location" --arg admin "$admin" --argjson cores "$vcores" '
      (.id|ascii_downcase)==($id|ascii_downcase) and (.location|ascii_downcase)==($region|ascii_downcase) and
      .properties.provisioningState=="Succeeded" and .properties.version=="17" and
      .properties.administratorLogin==$admin and .properties.vCores==$cores and
      .properties.replicaCount==1 and .properties.zonePlacementPolicy=="BestEffort"
      ' <<<"$existing" >/dev/null ||
      fail "Existing HorizonDB cluster state, region, administrator, version or sizing differs; refusing creation/update"
    reuse_cluster=true
    printf 'Verified existing HorizonDB cluster; ARM will not replay the cluster creation PUT.\n'
  fi
fi
if [[ "$reuse_admin" == true ]]; then
  ensure_horizon_admin "$cluster_id" "$identity_principal" "$identity_name" \
    "$identity_tenant" "$location" --existing-only
fi
# Read secrets from files and submit an @parameters file, never a password-valued CLI argument.
jq -n --rawfile password "$password_file" --slurpfile rules "$tmp/rules.json" \
  --arg cluster "$cluster" --arg location "$location" --arg admin "$admin" --argjson cores "$vcores" \
  --arg principal "$identity_principal" --arg identityName "$identity_name" --arg tenant "$identity_tenant" \
  --arg provider "$provider" --arg sku "$sku" --argjson storage "$storage" --argjson reuse "$reuse_cluster" '
  ($password | sub("\r?\n$"; "")) as $p |
  if ($p | length) < 8 or ($p | length) > 128 or ($p | contains("\r") or contains("\n") or contains("\u0000"))
  then error("Password must contain 8-128 characters on one line")
  else {
    clusterName: {value:$cluster}, location:{value:$location},
    administratorLogin:{value:$admin}, administratorLoginPassword:{value:$p},
    firewallRules:{value:$rules[0]}
  } + {dbProvider:{value:$provider}}
    + (if $principal != "" then {identityPrincipalId:{value:$principal},
         identityName:{value:$identityName},identityTenantId:{value:$tenant}} else {} end)
    + (if $provider == "horizondb" then {vCores:{value:$cores},reuseHorizonCluster:{value:$reuse}}
       else {skuName:{value:$sku},storageSizeGB:{value:$storage}} end) end' >"$tmp/parameters.json"
printf 'Target: subscription=%s resource-group=%s region=%s cluster=%s\n' \
  "$subscription" "$resource_group" "$location" "$cluster"
# -- Validate ARM before creating billable resources --------------------------
printf 'Validating %s template and explicit firewall rules...\n' "$provider"
if ! az deployment group validate --subscription "$subscription" --resource-group "$resource_group" \
  --template-file "$template" --parameters "@$tmp/parameters.json" --output none >"$tmp/diagnostics" 2>&1; then
  fail "ARM validation failed for $provider in $location; check access, capacity and parameters. CLI diagnostics are suppressed to protect credentials"
fi

# -- Provision and retain the resource identity for troubleshooting ------------
mkdir -p -- "$(dirname -- "$output")"
jq -n --arg id "$cluster_id" --arg region "$location" --arg provider "$provider" \
  '{status:"creating", resource_id:$id, region:$region, DB_PROVIDER:$provider}' >"$output"
recorded=true
stage="provisioning"
if ! az deployment group create --subscription "$subscription" --resource-group "$resource_group" \
  --name "module06-$cluster" --mode Incremental \
  --template-file "$template" --parameters "@$tmp/parameters.json" \
  --query properties.outputs --output json >"$tmp/result.json" 2>"$tmp/diagnostics"; then
  printf 'Inspect ARM deployment operations in the portal: %s (nested: module06-%s). Request bodies may contain credentials; do not share them.\n' \
    "module06-$cluster" "$provider" >&2
  fail "ARM provisioning failed for $provider; CLI diagnostics are suppressed to protect credentials"
fi
# -- Validate and save nonsecret connection settings --------------------------
stage="output-validation"
# Both providers expose the same connection contract, so Agent code does not branch by service.
# ARM success is not a connectivity check; deploy-aca.sh verifies schema access from the guests.
jq -e --arg provider "$provider" --arg id "$cluster_id" --arg region "$location" \
  --arg mode "$auth_mode" --arg admin "$admin" --arg identityName "$identity_name" \
  --arg client "$identity_client" --arg principal "$identity_principal" '
  {status:"provisioned", resource_id:.resourceId.value, region:.region.value, DB_PROVIDER:.provider.value,
   DB_ENDPOINT:.endpoint.value, DB_PORT:(.port.value|tostring),
   DB_DATABASE:.database.value, DB_USERNAME:.username.value,
   DB_SSL_MODE:.sslMode.value, DB_AUTH_MODE:(.authMode.value // "password"),
   DB_ADMIN_USERNAME:(.administratorUsername.value // $admin)}
  + (if $mode == "entra" then {DB_IDENTITY_CLIENT_ID:$client,DB_IDENTITY_PRINCIPAL_ID:$principal} else {} end)
  | if .resource_id == $id and .region == $region and .DB_PROVIDER == $provider
       and .DB_AUTH_MODE == $mode and .DB_ADMIN_USERNAME == $admin
       and .DB_USERNAME == (if $mode == "entra" then $identityName else $admin end)
       and .DB_DATABASE == "postgres" and .DB_PORT == "5432" and .DB_SSL_MODE == "require"
       and (.DB_USERNAME | type == "string" and length > 0)
       and (.DB_ENDPOINT | type == "string" and test("^[a-zA-Z0-9.-]+$")
            and . != "localhost" and . != "127.0.0.1" and . != "db") then .
    else error("Deployment did not return a database endpoint") end
' "$tmp/result.json" >"$tmp/status.json"
if [[ "$provider" == horizondb ]]; then
  stage="cluster-configuration"
  entra=Disabled
  if [[ "$auth_mode" == entra ]]; then entra=Enabled; fi
  configure_horizon_cluster "$cluster_id" "$location" "$admin" "$vcores" "$identity_tenant" "$entra"
fi
if [[ "$provider" == horizondb && "$auth_mode" == entra ]]; then
  stage="administrator"
  admin_args=()
  if [[ "$reuse_admin" == true ]]; then admin_args+=(--existing-only); fi
  ensure_horizon_admin "$cluster_id" "$identity_principal" "$identity_name" \
    "$identity_tenant" "$location" "${admin_args[@]}"
fi
mv -- "$tmp/status.json" "$output"
printf '%s provisioned. Nonsecret connection settings: %s\n' "$provider" "$output"
jq '{DB_PROVIDER,DB_ENDPOINT,DB_PORT,DB_DATABASE,DB_USERNAME,DB_SSL_MODE,DB_AUTH_MODE}' "$output"
printf 'Database connectivity/schema are not yet verified. Run the ACA script with --migrate for initial schema setup.\n'
