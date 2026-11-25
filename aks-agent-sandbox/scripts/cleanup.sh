#!/usr/bin/env bash
# cleanup.sh — Release workloads, snapshots and the dedicated lab group
#
# Usage: bash scripts/cleanup.sh --confirm-resource-group <resource-group-name>
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: lab ownership tag, controller/storage access and Foundry/APIM purge permissions.
# WARNING: deletes all lab resources and permanently purges Foundry and APIM data.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/5] Validate explicit confirmation, lab ownership and cluster selection ───
lab_step 1/5 "Validate explicit confirmation, lab ownership and cluster selection"
[[ $# == 2 && "$1" == --confirm-resource-group && "$2" == "$RESOURCE_GROUP" ]] ||
  die "Deletes the ENTIRE dedicated lab group and permanently purges Foundry/APIM. Usage: bash scripts/cleanup.sh --confirm-resource-group $RESOURCE_GROUP"
[[ "$(az group exists -n "$RESOURCE_GROUP")" == true ]] || {
  echo "Resource group already absent. Any remaining soft-deleted Foundry/APIM resource must be inspected and purged manually."
  exit 0
}

[[ "$(az group show -n "$RESOURCE_GROUP" --query tags.purpose -o tsv)" == aks-agent-sandbox-lab ]] ||
  die "Resource group is not tagged as a dedicated lab; refusing deletion."

clusters="$(az aks list -g "$RESOURCE_GROUP" --query '[].name' -o tsv)"
[[ -z "$clusters" || "$clusters" == "$CLUSTER_NAME" ]] ||
  die "Unexpected clusters in resource group; inspect manually."

# ── [2/5] Remove consumers and snapshots while their controllers are available ──
lab_step 2/5 "Remove consumers and snapshots while their controllers are available"
if [[ -n "$clusters" ]]; then
  connect

  api_exists() {
    local result
    result="$(kubectl get crd "$1" --ignore-not-found -o name)" ||
      die "Cannot query $1; refusing to bypass controller cleanup."
    [[ -n "$result" ]]
  }

  namespace="$(kubectl get namespace "$NAMESPACE" --ignore-not-found -o name)"
  if [[ -n "$namespace" ]]; then
    if api_exists podsnapshotmanualtriggers.podsnapshot.aks.azure.com; then
      triggers="$(kubectl -n "$NAMESPACE" get podsnapshotmanualtriggers -o name)"
      if [[ -n "$triggers" ]]; then
        kubectl -n "$NAMESPACE" wait --for=condition=Triggered \
          podsnapshotmanualtriggers --all --timeout="$TIMEOUT"
      fi
    fi

    if api_exists sandboxwarmpools.extensions.agents.x-k8s.io; then
      kubectl -n "$NAMESPACE" delete sandboxwarmpools --all \
        --cascade=foreground \
        --wait=true \
        --timeout="$TIMEOUT"
      kubectl -n "$NAMESPACE" delete sandboxclaims --all \
        --cascade=foreground \
        --wait=true \
        --timeout="$TIMEOUT"
      kubectl -n "$NAMESPACE" delete sandboxtemplates --all \
        --wait=true \
        --timeout="$TIMEOUT"
    fi

    if api_exists sandboxes.agents.x-k8s.io; then
      kubectl -n "$NAMESPACE" delete sandboxes --all \
        --cascade=foreground \
        --wait=true \
        --timeout="$TIMEOUT"
    fi

    kubectl -n "$NAMESPACE" delete pods --all --wait=true --timeout="$TIMEOUT"
    if api_exists podsnapshotmanualtriggers.podsnapshot.aks.azure.com; then
      kubectl -n "$NAMESPACE" delete podsnapshotmanualtriggers --all \
        --wait=true \
        --timeout="$TIMEOUT"
    fi

    if api_exists podsnapshots.podsnapshot.aks.azure.com; then
      kubectl -n "$NAMESPACE" delete podsnapshots --all --wait=true --timeout="$TIMEOUT"
      [[ -z "$(kubectl -n "$NAMESPACE" get podsnapshots -o name)" ]] ||
        die "Snapshots remain; preserve controllers and storage access until finalizers finish."
    fi

    kubectl delete namespace "$NAMESPACE" --wait=true --timeout="$TIMEOUT"
  fi
  kubectl delete pv "${NAMESPACE}-agent-state" \
    --ignore-not-found \
    --wait=true \
    --timeout="$TIMEOUT"

  # ── [3/5] Remove storage configuration after snapshot finalizers complete ─────
  lab_step 3/5 "Remove storage configuration after snapshot finalizers complete"
  if api_exists podsnapshotstorageconfigs.podsnapshot.aks.azure.com; then
    kubectl delete podsnapshotstorageconfig "$STORAGE_CONFIG" \
      --ignore-not-found \
      --wait=true \
      --timeout="$TIMEOUT"
  fi

fi

# ── [4/5] Permanently purge this lab's Foundry and APIM before deleting the group ─
lab_step 4/5 "Permanently purge this lab's Foundry and APIM before deleting the group"
subscription_id="$(az account show --query id -o tsv)"
[[ -n "$subscription_id" ]] || die "Cannot determine the deployment subscription."

list_purge_targets() {
  local service="$1"
  local state="$2"
  local accounts
  if [[ "$service" == apim && "$state" == active ]]; then
    accounts="$(az apim list \
      --subscription "$subscription_id" \
      -g "$RESOURCE_GROUP" \
      -o json)" || die "Cannot list active APIM services; refusing permanent cleanup."
  elif [[ "$service" == apim ]]; then
    accounts="$(az apim deletedservice list \
      --subscription "$subscription_id" \
      -o json)" || die "Cannot list soft-deleted APIM services; refusing permanent cleanup."
  elif [[ "$state" == active ]]; then
    accounts="$(az cognitiveservices account list \
      --subscription "$subscription_id" \
      -g "$RESOURCE_GROUP" \
      --query "[?kind=='AIServices'].{name:name,location:location,id:id}" \
      -o json)" || die "Cannot list active Foundry accounts; refusing permanent cleanup."
  else
    accounts="$(az cognitiveservices account list-deleted \
      --subscription "$subscription_id" \
      --query '[].{name:name,location:location,id:id}' \
      -o json)" || die "Cannot list soft-deleted Foundry accounts; refusing permanent cleanup."
  fi

  python3 - "$service" "$state" "$subscription_id" "$RESOURCE_GROUP" "$accounts" <<'PY'
import json
import re
import sys

service, state, subscription, group, payload = sys.argv[1:]
resource_type = "Microsoft.ApiManagement/service" if service == "apim" else "Microsoft.CognitiveServices/accounts"
name_prefix = "apim-sbox-" if service == "apim" else "foundry-sbox-"
records = set()
for account in json.loads(payload):
    if service == "apim" and state == "deleted":
        resource_id = account.get("serviceId") or account.get("properties", {}).get("serviceId")
        if not isinstance(resource_id, str):
            raise ValueError("Deleted APIM record is missing its original serviceId")
    else:
        resource_id = account["id"]
    resource_id = resource_id.lower()
    prefix = f"/subscriptions/{subscription}/resourceGroups/{group}/providers/{resource_type}/"
    pattern = re.escape(prefix.lower()) + r"([^/]+)"
    match = re.fullmatch(pattern, resource_id)
    if not match:
        if state == "active":
            raise ValueError("Resource is outside the confirmed resource group")
        continue
    name, location = account["name"], account["location"]
    if not name.startswith(name_prefix):
        continue
    if service == "apim" and state == "deleted":
        deleted_pattern = (
            re.escape(f"subscriptions/{subscription}/providers/Microsoft.ApiManagement/locations/".lower())
            + r"([a-z0-9]+)/deletedservices/" + re.escape(name.lower())
        )
        deleted_match = re.fullmatch(deleted_pattern, account["id"].lstrip("/").lower())
        if not deleted_match:
            raise ValueError("Invalid deleted APIM resource ID")
        location = deleted_match[1]
    elif service == "apim":
        location = location.replace(" ", "").lower()
    if not re.fullmatch(re.escape(name_prefix) + r"[a-z0-9-]+", name) or not re.fullmatch(r"[a-z0-9]+", location):
        raise ValueError("Invalid resource name or location")
    if match[1] != name.lower():
        raise ValueError("Resource name does not match its original resource ID")
    records.add((name, location))
for name, location in sorted(records):
    print(name + "\t" + location)
PY
}

list_foundry_projects() {
  local account="$1"
  local projects
  local project
  projects="$(az cognitiveservices account project list \
    --subscription "$subscription_id" \
    -g "$RESOURCE_GROUP" \
    -n "$account" \
    --query '[].name' \
    -o tsv)" || die "Cannot list projects in Foundry account $account; refusing account deletion."

  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    # ARM may return account/project rather than the leaf name the CLI needs.
    if [[ "$project" == "$account/"* ]]; then
      project="${project#"$account/"}"
    fi
    [[ -n "$project" && "$project" != */* ]] ||
      die "Invalid project name in Foundry account $account; refusing account deletion."
    printf '%s\n' "$project"
  done <<< "$projects"
}

active_foundry="$(list_purge_targets foundry active)"
while IFS=$'\t' read -r name location; do
  [[ -n "$name" ]] || continue
  projects="$(list_foundry_projects "$name")"
  while IFS= read -r project; do
    [[ -n "$project" ]] || continue
    echo "Deleting Foundry project $project in account $name before account deletion."
    az cognitiveservices account project delete \
      --subscription "$subscription_id" \
      -g "$RESOURCE_GROUP" \
      -n "$name" \
      --project-name "$project"
  done <<< "$projects"

  project_deadline=$((SECONDS + TIMEOUT_SECONDS))
  projects="$(list_foundry_projects "$name")"
  while [[ -n "$projects" ]]; do
    (( SECONDS < project_deadline )) ||
      die "Projects remain in Foundry account $name; refusing account deletion."
    echo "Waiting for projects in Foundry account $name to finish deleting..."
    sleep 5
    projects="$(list_foundry_projects "$name")"
  done

  echo "Deleting Foundry account $name ($location) before permanent purge."
  az cognitiveservices account delete \
    --subscription "$subscription_id" \
    -g "$RESOURCE_GROUP" \
    -n "$name"
done <<< "$active_foundry"

# Include prior soft deletions so a failed purge can be retried while the group exists.
deleted_foundry="$(list_purge_targets foundry deleted)"
purge_targets="$(printf '%s\n%s\n' "$active_foundry" "$deleted_foundry" | sort -u)"
while IFS=$'\t' read -r name location; do
  [[ -n "$name" ]] || continue
  echo "Permanently purging Foundry account $name ($location); this cannot be undone."
  az cognitiveservices account purge \
    --subscription "$subscription_id" \
    -g "$RESOURCE_GROUP" \
    -n "$name" \
    -l "$location"
done <<< "$purge_targets"

active_apim="$(list_purge_targets apim active)"
while IFS=$'\t' read -r name location; do
  [[ -n "$name" ]] || continue
  echo "Deleting APIM service $name ($location) before permanent purge."
  az apim delete \
    --subscription "$subscription_id" \
    -g "$RESOURCE_GROUP" \
    -n "$name" \
    --yes
done <<< "$active_apim"

deleted_apim="$(list_purge_targets apim deleted)"
purge_targets="$(printf '%s\n%s\n' "$active_apim" "$deleted_apim" | sort -u)"
while IFS=$'\t' read -r name location; do
  [[ -n "$name" ]] || continue
  echo "Permanently purging APIM service $name ($location); this cannot be undone."
  az apim deletedservice purge \
    --subscription "$subscription_id" \
    --service-name "$name" \
    --location "$location"
done <<< "$purge_targets"

purge_deadline=$((SECONDS + TIMEOUT_SECONDS))
remaining_foundry="$(list_purge_targets foundry deleted)"
remaining_apim="$(list_purge_targets apim deleted)"
while [[ -n "$remaining_foundry" || -n "$remaining_apim" ]]; do
  (( SECONDS < purge_deadline )) ||
    die "Foundry/APIM soft-deleted records remain after purge; retry cleanup after checking Azure status."
  sleep 5
  remaining_foundry="$(list_purge_targets foundry deleted)"
  remaining_apim="$(list_purge_targets apim deleted)"
done

# ── [5/5] Delete the dedicated resource group and remove local session state ────
lab_step 5/5 "Delete the dedicated resource group and remove local session state"
# Kubernetes cleanup must succeed before deleting identities, Blob data or the cluster.
az group delete -n "$RESOURCE_GROUP" --yes
[[ "$(az group exists -n "$RESOURCE_GROUP")" == false ]] || die "Resource group deletion is incomplete."

rm -f -- \
  "$ROOT/.lab/snapshot-name" \
  "$ROOT/.lab/before.json" \
  "$ROOT/.lab/after.json" \
  "$ROOT/.lab/session-source.json" \
  "$ROOT/.lab/session-restore.yaml" \
  "$ROOT/.lab/image.json" \
  "$ROOT/.lab/outputs.json" \
  "$ROOT/.lab/warm-pool.yaml"

echo "Lab group deleted and Foundry/APIM permanently purged, including AKS, VNet/Private Link, Blob, ACR and identities."
