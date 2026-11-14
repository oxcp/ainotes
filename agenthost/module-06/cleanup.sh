#!/usr/bin/env bash
# cleanup.sh -- Remove Module-06 resources and generated configuration.
#
#   1. Read saved inventories and verify ownership of Module-06 resources
#   2. Preview exact deletion targets and require explicit confirmation
#   3. Delete cloud resources in dependency order and verify their absence
#   4. Remove generated local files only after complete cloud cleanup
#
# Usage: bash cleanup.sh [--execute]
# Env overrides: SUBSCRIPTION_ID, RESOURCE_GROUP, OPERATION_TIMEOUT_SECONDS.
# Scope comes from saved inventories; overrides must agree with their values.
# Prerequisites: jq, realpath, timeout; az/aca when cloud inventories require them.
# Never deletes the shared Module-01/04 infrastructure.
set +x
set -Eeuo pipefail
umask 077
case "${OSTYPE:-}" in
  msys* | cygwin*) export MSYS2_ARG_CONV_EXCL="/subscriptions/;${MSYS2_ARG_CONV_EXCL:-}" ;;
esac
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() {
  printf '\033[1;33mError [cleanup]: %s\033[0m\n' "$*" >&2
  exit 1
}
trap 'rc=$?; printf "\033[1;33mCleanup stopped (%s); recovery files retained. Review the error before retrying.\033[0m\n" "$rc" >&2; exit "$rc"' ERR
# -- Command-line options and required tools ---------------------------------
execute=false
while (($#)); do
  case "$1" in
    --execute)
      execute=true
      ;;
    --help)
      cat <<'HELP'
Usage: bash cleanup.sh [--execute]
Default: read-only discovery and a dry-run plan.
--execute requires typing "delete module-06" (also accepted on stdin).
Fixed scope: all five Module-06 agent roles across saved deployment attempts,
their disks and attributable snapshots, Module-06 data container/volume,
tagged databases/parameter groups, and baseline-tracked embedding/APIM children.
Never deletes the shared RG, SandboxGroup, UAMI, ACR, Foundry account/project,
general model, base APIM API/policy/backend, VNet, or storage account.
Inventories are discovered in this module's .local/*.json; no name-only deletion.
Missing ownership/baselines are reported, not guessed. Keep backups outside the
objects being deleted: this cleanup intentionally deletes attributable snapshots.
HELP
      exit 0
      ;;
    *) fail "Unknown option: $1 (use --help)" ;;
  esac
  shift
done
for tool in jq realpath timeout; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
jq() {
  case "${OSTYPE:-}" in
    msys* | cygwin*) command jq --binary "$@" ;;
    *) command jq "$@" ;;
  esac
}
operation_timeout="${OPERATION_TIMEOUT_SECONDS:-300}"
[[ "$operation_timeout" =~ ^[1-9][0-9]{0,4}$ ]] || fail "Invalid OPERATION_TIMEOUT_SECONDS"
safe_file() {
  local file="$1"
  [[ ! -L "$file" && (! -e "$file" || -f "$file") ]] || fail "Not a regular nonsymlink file: $file"
  [[ "$(realpath -m -- "$file")" == "$file" ]] || fail "Symlinked/noncanonical path refused: $file"
}
[[ ! -L "$root/.local" ]] || fail ".local must not be a symbolic link"
# -- Read saved deployment inventories; do not derive deletion targets by name
echo "==> [1/4] Reading inventories and validating Module-06 ownership"
aca_inventories='[]'
db_inventories='[]'
storage_inventories='[]'
inventory_files=()
shopt -s nullglob
for file in "$root/.local/"*.json; do
  safe_file "$file"
  # Read metadata only; runtime config may contain credentials.
  kind="$(jq -er 'if type!="object" then "other"
    elif has("agents") and has("deployment_id") then "aca"
    elif has("resource_id") and has("DB_PROVIDER") then "db"
    elif .kind=="module06-storage" then "storage"
    else "other" end' "$file")" || {
    case "${file##*/}" in aca-deployment* | database-deployment* | storage-deployment*) fail "Malformed inventory: $file" ;; esac
    continue
  }
  if [[ "$kind" == other ]]; then
    case "${file##*/}" in aca-deployment* | database-deployment* | storage-deployment*) fail "Unrecognized deployment inventory: $file" ;; esac
  fi
  case "$kind" in
    aca)
      inventory="$(jq -ce '
          def token: type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
          .deployment_id as $d |
          select((.subscription|token) and (.resource_group|token) and (.sandbox_group|token) and (.region|token)
            and ($d|test("^([0-9]{8}-[0-9]{6}-[0-9a-f]{6}|[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12})$"))
            and (.agents|keys)==["chat","data-processing","orchestrator","rag","sql"]
            and all(.agents|to_entries[];
              all([.value.disk_id,.value.sandbox_id][]; .==null or token) and
              (.value.disk_name==null or .value.disk_name==("studio-"+.key+"-"+$d))))
        ' "$file")" || fail "Invalid ACA inventory: $file"
      aca_inventories="$(jq -c --argjson i "$inventory" '.+[$i]' <<<"$aca_inventories")"
      inventory_files+=("$file")
      ;;
    db)
      inventory="$(jq -ce 'select(
        (.DB_PROVIDER=="horizondb" and (.resource_id|test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.HorizonDb/clusters/[A-Za-z0-9-]+$";"i")))
        or (.DB_PROVIDER=="postgresql" and (.resource_id|test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.DBforPostgreSQL/flexibleServers/[A-Za-z0-9-]+$";"i")))) |
        {DB_PROVIDER,resource_id}' "$file")" || fail "Invalid DB inventory: $file"
      db_inventories="$(jq -c --argjson i "$inventory" '.+[$i]|unique_by(.resource_id|ascii_downcase)' <<<"$db_inventories")"
      inventory_files+=("$file")
      ;;
    storage)
      inventory="$(jq -ce 'select(.module=="module-06" and
        (.container_id|test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[a-z0-9]{3,24}/blobServices/default/containers/data$")))' "$file")" \
        || fail "Invalid Module-06 storage inventory: $file"
      storage_inventories="$(jq -c --argjson i "$inventory" '.+[$i]|unique_by(.container_id)' <<<"$storage_inventories")"
      inventory_files+=("$file")
      ;;
  esac
done
# -- Resolve one subscription/resource group from all saved inventories -------
subscription="${SUBSCRIPTION_ID:-}"
resource_group="${RESOURCE_GROUP:-}"
set_scope() {
  local sub="$1" rg="$2"
  [[ -z "$subscription" || "${subscription,,}" == "${sub,,}" ]] || fail "Inventories have different subscriptions"
  [[ -z "$resource_group" || "${resource_group,,}" == "${rg,,}" ]] || fail "Inventories have different resource groups"
  subscription="$sub"
  resource_group="$rg"
}
while IFS=$'\t' read -r sub rg; do
  [[ -z "$sub" ]] || set_scope "$sub" "$rg"
done < <(jq -rn --argjson a "$aca_inventories" --argjson d "$db_inventories" --argjson s "$storage_inventories" '
  ($a[]|[.subscription,.resource_group]|@tsv),
  ($d[].resource_id|split("/")|[.[2],.[4]]|@tsv),
  ($s[].container_id|split("/")|[.[2],.[4]]|@tsv)')
aca_scope="$(jq -c '[.[]|{sandbox_group,region}]|unique' <<<"$aca_inventories")"
[[ "$(jq length <<<"$aca_scope")" -le 1 ]] || fail "Inventories span SandboxGroups/regions; split and review them manually"
sandbox_group="$(jq -r '.[0].sandbox_group // ""' <<<"$aca_scope")"
region="$(jq -r '.[0].region // ""' <<<"$aca_scope")"

# -- Load embedding/APIM ownership baselines and check Azure account scope ----
# Baselines contain only child IDs and before/after state, never credentials.
source "$root/common/cleanup-ownership.sh"
ledger="$root/.local/cleanup-ownership.json"
safe_file "$ledger"
ownership='{"version":1,"resources":[]}'
if [[ -f "$ledger" ]]; then
  ownership="$(jq -ce 'select(.version==1 and (.resources|type=="array"))' "$ledger")" \
    || fail "Invalid ownership baseline"
  while IFS=$'\t' read -r sub rg; do
    [[ -z "$sub" ]] || set_scope "$sub" "$rg"
  done < <(jq -r '.resources[].id|split("/")|[.[2],.[4]]|@tsv' <<<"$ownership")
fi
if [[ -n "$subscription" ]]; then
  command -v az >/dev/null || fail "Required tool missing: az"
  account="$(timeout "$operation_timeout" az account show --subscription "$subscription" -o json)" \
    || fail "Cannot read the selected Azure subscription"
  jq -e --arg sub "$subscription" '(.id|ascii_downcase)==($sub|ascii_downcase)' <<<"$account" >/dev/null \
    || fail "Azure account scope mismatch"
fi
aca_call() {
  timeout "$operation_timeout" aca "$@" \
    --subscription "$subscription" \
    --resource-group "$resource_group" \
    --group "$sandbox_group" \
    --region "$region" \
    -o json
}
resource_list() {
  local result args=()
  [[ "${2:-group}" != group ]] || args=(--resource-group "$resource_group")
  result="$(timeout "$operation_timeout" az resource list --subscription "$subscription" "${args[@]}" \
    --resource-type "$1" -o json)" || fail "Cannot list $1; failed reads are not absence"
  jq -ce 'select(type=="array" and all(.[]; .id|type=="string"))' <<<"$result" || fail "Invalid ARM resource list"
}
owned_resource() {
  local id="$2" candidates live api=2026-05-01-preview
  candidates="$(jq -ce --arg id "$id" 'map(select((.id|ascii_downcase)==($id|ascii_downcase))) |
    if length==0 then [] elif length==1 and .[0].tags.module=="module-06" then [.[0].id]
    else error("Missing module-06 ownership tag") end' <<<"$1")" || fail "Unowned resource: $id"
  if [[ "$candidates" == '[]' ]]; then
    printf '[]\n'
    return
  fi
  [[ "${id,,}" != *"/microsoft.dbforpostgresql/"* ]] || api=2024-08-01
  # The generic ARM inventory can lag deletion; verify with the provider collection,
  # using the same complete-read contract as the per-resource deletion check.
  live="$(ownership_read "$id" "$api")" || fail "Cannot verify discovered resource: $id"
  if [[ "$live" == null ]]; then
    printf '[]\n'
    return
  fi
  jq -ce --arg id "$id" 'select(
    (.id|ascii_downcase)==($id|ascii_downcase) and .tags.module=="module-06") | [.id]' \
    <<<"$live" || fail "Live resource ownership mismatch: $id"
}
# -- Build a safe plan from live resources and retained-reference checks ------
plan() {
  local aca_plan='{"sandboxes":[],"snapshots":[],"disks":[],"volumes":[],"containers":[],"unattributed_snapshots":[]}'
  local databases='[]' parameters='[]' children='[]' limitations='[]'
  local sandboxes disks snapshots volumes id type resources ids parameter clusters detail target live
  if [[ "$aca_inventories" != '[]' ]]; then
    command -v aca >/dev/null || fail "Required tool missing: aca"
    sandboxes="$(aca_call sandbox list)" || fail "Cannot list sandboxes"
    disks="$(aca_call sandboxgroup disk list)" || fail "Cannot list disks"
    snapshots="$(aca_call sandboxgroup snapshot list)" || fail "Cannot list snapshots"
    volumes="$(aca_call sandboxgroup volume list)" || fail "Cannot list volumes"
    aca_plan="$(jq -cne --argjson inventories "$aca_inventories" --argjson sandboxes "$sandboxes" \
      --argjson disks "$disks" --argjson snapshots "$snapshots" --argjson volumes "$volumes" \
      -f "$root/common/cleanup-aca.jq")" || fail "ACA ownership/reference validation failed"
  fi
  ids='[]'
  while IFS= read -r id; do
    if [[ -n "${volumes:-}" ]]; then
      jq -e --arg id "$id" --argjson planned "$(jq -c .volumes <<<"$aca_plan")" '
        all(.[]|select(.storageContainerResourceId==$id);
          (.volumeName // .name) as $n|$planned|index($n)!=null)' <<<"$volumes" >/dev/null \
        || fail "Data container is referenced by a retained volume"
    fi
    live="$(ownership_read "$id" 2023-01-01)" || fail "Cannot inspect data container"
    if [[ "$live" != null ]]; then
      jq -e '.properties.publicAccess=="None"' <<<"$live" >/dev/null \
        || fail "Data container differs from Module-06 private storage configuration"
      ids="$(jq -c --arg id "$id" '.+[$id]' <<<"$ids")"
    fi
  done < <(jq -rn --argjson a "$aca_plan" --argjson s "$storage_inventories" '[$a.containers[],$s[].container_id]|unique[]')
  aca_plan="$(jq -c --argjson ids "$ids" '.containers=$ids' <<<"$aca_plan")"
  while IFS= read -r id; do
    type=Microsoft.HorizonDb/clusters
    [[ "${id,,}" != *"/microsoft.dbforpostgresql/"* ]] || type=Microsoft.DBforPostgreSQL/flexibleServers
    resources="$(resource_list "$type")" || fail "Database discovery failed"
    ids="$(owned_resource "$resources" "$id")" || fail "Database ownership failed"
    databases="$(jq -c --argjson ids "$ids" '.+$ids|unique' <<<"$databases")"
    if [[ "$type" == Microsoft.HorizonDb/clusters ]]; then
      parameter="${id%/*/*}/parameterGroups/${id##*/}-vector"
      resources="$(resource_list Microsoft.HorizonDb/parameterGroups)" || fail "Parameter discovery failed"
      ids="$(owned_resource "$resources" "$parameter")" || fail "Parameter ownership failed"
      if [[ "$ids" != '[]' ]]; then
        clusters="$(resource_list Microsoft.HorizonDb/clusters subscription)" || fail "Reference discovery failed"
        while IFS= read -r target; do
          [[ "${target,,}" != "${id,,}" ]] || continue
          detail="$(timeout "$operation_timeout" az resource show --ids "$target" --api-version 2026-05-01-preview -o json)" \
            || fail "Cannot inspect parameter references"
          jq -e --arg id "$target" --arg group "$parameter" '
            (.id|ascii_downcase)==($id|ascii_downcase) and (.properties|type=="object") and
            ((.properties.parameterGroup.id // ""|ascii_downcase)!=($group|ascii_downcase))
          ' <<<"$detail" >/dev/null || fail "Parameter group is shared or references cannot be verified"
        done < <(jq -r '.[].id' <<<"$clusters")
      fi
      parameters="$(jq -c --argjson ids "$ids" '.+$ids|unique' <<<"$parameters")"
    fi
  done < <(jq -r '.[].resource_id' <<<"$db_inventories")
  while IFS= read -r target; do
    ownership_validate_target "$target"
    live="$(ownership_read "$(jq -r .id <<<"$target")" "$(jq -r .api <<<"$target")")" || fail "Cannot read tracked child"
    if [[ "$live" != null ]]; then
      jq -e --argjson live "$live" '.after!=null and .after==($live|del(.etag,.properties.provisioningState))' \
        <<<"$target" >/dev/null || fail "Tracked child changed, or deployment did not capture its final state: $(jq -r .id <<<"$target")"
      children="$(jq -c --argjson t "$target" '.+[$t|{id,api}]' <<<"$children")"
    fi
  done < <(jq -c '.resources|sort_by(if .kind=="operation" then 0 elif .kind=="backend" then 1 else 2 end)[]' <<<"$ownership")
  # Older deployments did not save APIM/model prior state. Never invent it.
  if [[ -f "$root/.local/embedding-config.json" || "$aca_inventories" != '[]' ]]; then
    if ! jq -e '.resources|any(.kind=="embedding")' <<<"$ownership" >/dev/null; then
      limitations="$(jq -c '.+["Legacy embeddings/APIM metadata has no baseline: model deployment, embeddings operation/policy and module06-embeddings-backend require manual prior-state review."]' <<<"$limitations")"
    fi
    if [[ "$aca_inventories" == '[]' && -f "$root/.local/aca-config.json" ]]; then
      limitations="$(jq -c '.+["Agent configuration exists without an ACA inventory: cannot establish sandbox/disk/volume ownership; review cloud inventory manually."]' <<<"$limitations")"
    fi
    if [[ "$db_inventories" == '[]' && -f "$root/.local/database-password" ]]; then
      limitations="$(jq -c '.+["Database credentials exist without a DB inventory: database ownership/absence cannot be verified; credentials retained."]' <<<"$limitations")"
    fi
  fi
  jq -cnS --argjson a "$aca_plan" --argjson database "$databases" --argjson parameters "$parameters" \
    --argjson children "$children" --argjson limitations "$limitations" \
    '$a+{database:$database,parameters:$parameters,children:$children,limitations:$limitations}'
}
# -- Preview cloud targets and generated local files before confirmation ------
echo "==> [2/4] Building and reviewing the exact cleanup plan"
files=("${inventory_files[@]}")
for name in aca-common.json aca-config.json embedding-config.json a2a-key studio-key database-password cleanup-ownership.json; do
  safe_file "$root/.local/$name"
  [[ ! -f "$root/.local/$name" ]] || files+=("$root/.local/$name")
done
initial_plan="$(plan)" || fail "Cannot build a safe cleanup plan"
printf 'Cloud cleanup plan (exact IDs; retained/limitations are NOT deletions):\n'
jq . <<<"$initial_plan"
printf 'Local generated files (removed only after complete cloud cleanup):\n'
if ((${#files[@]})); then
  printf '  %s\n' "${files[@]}"
fi
printf '%s\n' 'Shared infrastructure and unrelated Module-04 sandboxes are preserved.'
printf '\033[1;33m%s\033[0m\n' \
  'Back up valuable state outside this deletion scope first; attributable snapshots will also be deleted.'
if ! $execute; then
  printf 'DRY RUN: nothing changed. Use --execute to apply.\n'
  exit 0
fi
printf '\033[1;33mType "delete module-06" to confirm: \033[0m'
read -r answer || fail "Confirmation required"
[[ "$answer" == 'delete module-06' ]] || fail "Confirmation did not match"
confirmed_plan="$(plan)" || fail "Cannot revalidate plan"
[[ "$confirmed_plan" == "$initial_plan" ]] || fail "Cloud plan changed; rerun and review"
# -- Verify each resource's absence after deletion ----------------------------
present() {
  local kind="$1" id="$2" api="${3:-}" live
  case "$kind" in
    sandboxes) live="$(aca_call sandbox list)" || return 2 ;;
    snapshots) live="$(aca_call sandboxgroup snapshot list)" || return 2 ;;
    disks) live="$(aca_call sandboxgroup disk list)" || return 2 ;;
    volumes) live="$(aca_call sandboxgroup volume list)" || return 2 ;;
    *)
      live="$(ownership_read "$id" "$api")" || return 2
      [[ "$live" != null ]]
      return
      ;;
  esac
  jq -e --arg kind "$kind" 'type=="array" and all(.[];
    (if $kind=="volumes" then (.volumeName // .name) else .id end)|type=="string")' \
    <<<"$live" >/dev/null || return 2
  jq -e --arg id "$id" --arg kind "$kind" 'any(.[];
    (if $kind=="volumes" then (.volumeName // .name) else .id end)==$id)' <<<"$live" >/dev/null
}
# -- Delete cloud resources in dependency order -------------------------------
echo "==> [3/4] Deleting and verifying Module-06 cloud resources"
for kind in sandboxes snapshots disks volumes containers database parameters children; do
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    id="$(jq -r 'if type=="object" then .id else . end' <<<"$item")"
    printf 'Deleting %s: %s\n' "$kind" "$id"
    case "$kind" in
      sandboxes) aca_call sandbox delete --id "$id" --yes >/dev/null ;;
      snapshots) aca_call sandboxgroup snapshot delete --id "$id" >/dev/null ;;
      disks) aca_call sandboxgroup disk delete --id "$id" >/dev/null ;;
      volumes) aca_call sandboxgroup volume delete --name "$id" >/dev/null ;;
      children)
        api="$(jq -r .api <<<"$item")"
        live="$(ownership_read "$id" "$api")" || fail "Cannot revalidate child immediately before deletion"
        [[ "$live" != null ]] || continue
        jq -e --arg id "$id" --argjson live "$live" '
          .resources[]|select(.id==$id)|.after==($live|del(.etag,.properties.provisioningState))' \
          <<<"$ownership" >/dev/null || fail "Child changed before deletion: $id"
        headers=()
        etag="$(jq -r '.etag // ""' <<<"$live")"
        [[ -z "$etag" ]] || headers=(--headers "If-Match=$etag")
        timeout "$operation_timeout" az rest --method delete \
          --url "https://management.azure.com$id?api-version=$api" "${headers[@]}" -o none
        ;;
      *)
        api=2026-05-01-preview
        [[ "$kind" != containers ]] || api=2023-01-01
        [[ "${id,,}" != *"/microsoft.dbforpostgresql/"* ]] || api=2024-08-01
        timeout "$operation_timeout" az resource delete --ids "$id" --api-version "$api" -o none
        ;;
    esac
    absent=false
    for attempt in {1..12}; do
      [[ "$kind" != children ]] || api="$(jq -r .api <<<"$item")"
      rc=0
      present "$kind" "$id" "${api:-}" || rc=$?
      ((rc <= 1)) || fail "Cannot verify deletion"
      if ((rc == 1)); then
        absent=true
        break
      fi
      sleep 5
    done
    $absent || fail "Deletion not confirmed: $id; recovery files retained"
  done < <(jq -c --arg kind "$kind" '.[$kind][]' <<<"$initial_plan")
done
# -- Verify complete cloud cleanup before removing generated configuration ----
echo "==> [4/4] Verifying final cloud state and removing generated local files"
final_plan="$(plan)" || fail "Cannot verify final cleanup"
jq -e 'all(to_entries[]|select(.key!="limitations" and .key!="unattributed_snapshots"); .value|length==0)' \
  <<<"$final_plan" >/dev/null || {
  printf '\033[1;33mRemaining cloud cleanup plan (limitations and unattributed snapshots are not deletion targets):\033[0m\n' >&2
  jq . <<<"$final_plan" >&2
  fail "Resources remain; recovery files retained"
}
if jq -e '.limitations|length>0' <<<"$final_plan" >/dev/null; then
  while IFS= read -r limitation; do
    printf '\033[1;33m%s\033[0m\n' "$limitation" >&2
  done < <(jq -r '.limitations[]' <<<"$final_plan")
  fail "Partial cleanup only; unverified ownership/prior state requires review; local files retained"
fi
for file in "${files[@]}"; do
  safe_file "$file"
done
for file in "${files[@]}"; do
  rm -f -- "$file"
done
printf '\033[1;32mModule-06 cleanup complete. Unattributed snapshots, custom inputs and shared resources retained.\033[0m\n'
