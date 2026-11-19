#!/usr/bin/env bash
# rebuild-agents.sh -- Replace only the five Module-06 Agent sandboxes.
#
#   1. Validate the saved deployment, configuration and live sandbox ownership
#   2. Confirm the targets and build five images before interrupting service
#   3. Optionally snapshot, delete recorded sandboxes and verify their removal
#   4. Deploy five new sandboxes using the existing database and Blob storage
#
# Usage: bash rebuild-agents.sh [--snapshot] [--yes]
# Prerequisites: an existing Module-06 deployment; see rebuild-agents.md.

set +x
set -euo pipefail
umask 077

# -- 1. Options and helpers --------------------------------------------------
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
inventory="${OLD_ACA_OUTPUT:-$root/.local/aca-deployment.json}"
config="${ACA_CONFIG:-$root/.local/aca-config.json}"
output=""
tag=""
snapshot=false
yes=false
stage=preflight
roles=(chat orchestrator data-processing rag sql)

usage() {
  cat <<'HELP'
Usage: bash rebuild-agents.sh [options]
  --inventory FILE   Old deployment inventory (OLD_ACA_OUTPUT or .local/aca-deployment.json)
  --config FILE      Existing protected configuration (ACA_CONFIG or .local/aca-config.json)
  --output FILE      New inventory; defaults to a unique .local/aca-deployment-rebuild-*.json
  --tag TAG          Build/deploy tag; defaults to a unique rebuild-* tag
  --snapshot         Snapshot every remaining recorded sandbox before deleting any
  --yes              Skip the interactive "rebuild module-06" confirmation
  --help

Builds first, then deletes only recorded sandbox IDs with matching live deployment/role
labels and source disk IDs. Existing database, Blob data, configuration, disks,
snapshots, volumes and shared resources are preserved. No schema migration is run.
Builds and sandbox operations incur charges. Snapshot valuable guest-local state first.
All Azure/ACA calls use the subscription/group/region from the old inventory.
Restore custom ACR_NAME, ACA_COMMON, identity and network settings before running.
Ambient IMAGE_TAG and ACA_OUTPUT are not reused; use --tag/--output to override.
Relative explicit paths are relative to the caller's directory.
Requires Bash, az, aca, jq, curl, openssl and GNU timeout. Does not install tools.
HELP
}

fail() {
  printf 'Error [rebuild:%s]: %s\n' "$stage" "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --inventory | --config | --output | --tag)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || fail "Missing value for $1"
      case "$1" in
        --inventory)
          inventory="$2"
          ;;
        --config)
          config="$2"
          ;;
        --output)
          output="$2"
          ;;
        --tag)
          tag="$2"
          ;;
      esac
      shift 2
      ;;
    --snapshot)
      snapshot=true
      shift
      ;;
    --yes)
      yes=true
      shift
      ;;
    *)
      fail "Unknown option: $1 (use --help)"
      ;;
  esac
done

trap 'printf "Rebuild stopped at stage %s. Preserve old/new inventories; no rollback or later stages ran.\n" "$stage" >&2' ERR

for tool in az aca jq curl openssl timeout; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
for file in build-images.sh deploy.sh common/aca-config.jq; do
  [[ -f "$root/$file" ]] || fail "Required module file missing: $file"
done
bash -n "$root/build-images.sh"
bash -n "$root/deploy.sh"
[[ -f "$inventory" ]] || fail "Old inventory not found: $inventory"
[[ -f "$config" ]] || fail "Existing runtime configuration not found: $config"
[[ ! -L "$root/.local" ]] || fail "Artifact directory must not be a symbolic link"

saved="$(jq -ce '
  def token: type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
  if type=="object"
    and all([.subscription,.resource_group,.sandbox_group,.region,.deployment_id][]; token)
    and (.agents|type=="object")
    and (.agents|keys)==["chat","data-processing","orchestrator","rag","sql"]
    and all(.agents[]; (.sandbox_id|token) and (.disk_id|token))
    and ([.agents[].sandbox_id]|unique|length)==5
    and ([.agents[].disk_id]|unique|length)==5
  then . else error("Expected a complete five-Agent deployment inventory") end
' "$inventory")"
jq -e -f "$root/common/aca-config.jq" "$config" >/dev/null \
  || fail "Invalid runtime configuration; preserve and inspect it before rebuilding"

SUBSCRIPTION_ID="$(jq -r '.subscription' <<<"$saved")"
RESOURCE_GROUP="$(jq -r '.resource_group' <<<"$saved")"
SANDBOX_GROUP_NAME="$(jq -r '.sandbox_group' <<<"$saved")"
LOCATION="$(jq -r '.region' <<<"$saved")"
DB_PROVIDER="$(jq -r '.chat.DB_PROVIDER // "horizondb"' "$config")"
run_id="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 3)"
IMAGE_TAG="${tag:-rebuild-$run_id}"
ACA_OUTPUT="${output:-$root/.local/aca-deployment-rebuild-$run_id.json}"
ACA_CONFIG="$config"
export SUBSCRIPTION_ID RESOURCE_GROUP SANDBOX_GROUP_NAME LOCATION
export DB_PROVIDER IMAGE_TAG ACA_OUTPUT ACA_CONFIG

[[ ! -e "$ACA_OUTPUT" && ! -L "$ACA_OUTPUT" ]] \
  || fail "New output already exists; preserve it and choose a different --output"
operation_timeout="${OPERATION_TIMEOUT_SECONDS:-900}"
[[ "$operation_timeout" =~ ^[1-9][0-9]*$ ]] || fail "Invalid OPERATION_TIMEOUT_SECONDS"

aca_args=(
  --subscription "$SUBSCRIPTION_ID"
  --resource-group "$RESOURCE_GROUP"
  --group "$SANDBOX_GROUP_NAME"
  --region "$LOCATION"
)

aca_call() {
  timeout --foreground "$operation_timeout" aca "$@" "${aca_args[@]}" -o json
}

live_targets() {
  local live
  live="$(aca_call sandbox list)" || return $?
  jq -ce --argjson saved "$saved" '
    def token: type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    if type!="array" then error("Expected sandbox list array") else . end |
    if all(.[]; .id|token) and ([.[].id]|unique|length)==length
    then . else error("Malformed or duplicate sandbox IDs") end |
    . as $live |
    [$saved.agents|to_entries[]|
      .key as $role|.value as $record|
      $live[]|select(.id==$record.sandbox_id)|
      if .labels.deployment==$saved.deployment_id and .labels.role==$role
        and .sourcesRef.diskImage.id==$record.disk_id
      then {role:$role,id:.id}
      else error("Recorded sandbox ownership/source mismatch") end]
  ' <<<"$live"
}

# -- 2. Read-only preflight and confirmation ---------------------------------
az account show -o none 2>/dev/null || az login
aca auth status >/dev/null 2>&1 || aca auth login
az account show --subscription "$SUBSCRIPTION_ID" -o none
aca doctor \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --sandbox-group "$SANDBOX_GROUP_NAME" \
  --region "$LOCATION"

(
  source "$root/build-images.sh"
  images_preflight --tag "$IMAGE_TAG"
)
targets="$(live_targets)"
[[ "$(jq 'length' <<<"$targets")" -gt 0 ]] \
  || fail "No recorded sandboxes remain. Inspect previous rebuild inventories before retrying or select the current --inventory"

printf '\nTarget: %s / %s / %s (%s)\n' \
  "$SUBSCRIPTION_ID" "$RESOURCE_GROUP" "$SANDBOX_GROUP_NAME" "$LOCATION"
printf 'Old inventory: %s\nNew inventory: %s\nImage tag: %s\n' \
  "$inventory" "$ACA_OUTPUT" "$IMAGE_TAG"
jq -r '.[] | [.role,.id] | @tsv' <<<"$targets"
printf '\nOnly the listed sandboxes will be deleted after the image build.\n'
printf 'Database, Blob data, runtime configuration and shared resources are retained.\n'
printf 'WARNING: back up valuable guest-local state; use --snapshot before deletion.\n'
if ! $yes; then
  printf 'Type "rebuild module-06" to continue: '
  IFS= read -r confirmation || fail "Confirmation required; no build or deletion started"
  [[ "$confirmation" == "rebuild module-06" ]] || fail "Cancelled; no build or deletion started"
fi

# -- 3. Build first so build failure leaves the old Agents running ------------
stage=images
bash "$root/build-images.sh" --tag "$IMAGE_TAG"

# Recheck ownership after the potentially long build, before any destructive call.
stage=ownership
targets="$(live_targets)"

if $snapshot; then
  stage=snapshots
  for role in "${roles[@]}"; do
    sandbox_id="$(jq -r --arg role "$role" '.[]|select(.role==$role)|.id' <<<"$targets")"
    [[ -n "$sandbox_id" ]] || continue
    snapshot_name="before-rebuild-$role-$run_id"
    printf 'Snapshotting %s: %s as %s\n' "$role" "$sandbox_id" "$snapshot_name"
    aca_call sandbox snapshot \
      --id "$sandbox_id" \
      --name "$snapshot_name" >/dev/null
  done
fi

# -- 4. Delete recorded sandboxes only and wait for removal -------------------
stage=delete
for role in "${roles[@]}"; do
  sandbox_id="$(jq -r --arg role "$role" '.[]|select(.role==$role)|.id' <<<"$targets")"
  if [[ -z "$sandbox_id" ]]; then
    printf 'Skipping %s: recorded sandbox is already absent.\n' "$role"
    continue
  fi
  printf 'Deleting %s: %s\n' "$role" "$sandbox_id"
  aca_call sandbox delete --id "$sandbox_id" --yes >/dev/null
done

for attempt in {1..6}; do
  remaining="$(live_targets)"
  if [[ "$(jq 'length' <<<"$remaining")" == 0 ]]; then
    break
  fi
  ((attempt < 6)) || fail "Sandbox deletion is still pending; deployment was not started"
  sleep 5
done

# -- 5. Reuse the existing configuration, database and Blob storage -----------
stage=aca
bash "$root/deploy.sh" --stage aca

stage=verify
jq -e --arg tag "$IMAGE_TAG" '
  .status=="ready"
  and (.agents|keys)==["chat","data-processing","orchestrator","rag","sql"]
  and all(.agents[]; .status=="ready" and (.image|endswith(":"+$tag)))
  and (.agents.chat.url|type=="string" and startswith("https://"))
' "$ACA_OUTPUT" >/dev/null || fail "New inventory did not confirm five ready Agents using the new tag"

printf '\nRebuild complete. Old disks/snapshots and persisted data were retained.\n'
printf 'Inventory: %s\nChat URL: ' "$ACA_OUTPUT"
jq -r '.agents.chat.url' "$ACA_OUTPUT"
