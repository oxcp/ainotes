#!/usr/bin/env bash
# common.sh — Shared configuration and helpers for the AKS Agent Sandbox lab
#
# Usage: source this file from a lab script.
# Env override: CONFIG_FILE (defaults to the lab's .env).
# Prerequisites: configured .env, Azure CLI and Python 3.

set -euo pipefail

# ── Script presentation without changing command substitutions or pipelines ──
lab_step() {
  printf '__LAB_STEP__[%s] %s\n' "$1" "$2"
}

lab_output() {
  local color="$1"
  local line
  local refresh=false
  local collecting=false
  local previous_rows=0
  local terminal_fd
  local rows columns limit index
  local -a frame=()
  if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
    refresh=true
    exec {terminal_fd}>&1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == __LAB_PROGRESS_BEGIN__ ]]; then
      frame=()
      collecting=true
    elif [[ "$line" == __LAB_PROGRESS_FRAME__ || "$line" == __LAB_PROGRESS_DONE__ ]]; then
      collecting=false
      if [[ "$refresh" == true ]]; then
        if ! read -r rows columns < <(stty size <&"$terminal_fd") ||
          (( rows < 5 || columns < 6 )); then
          printf 'WARNING: Terminal size unavailable or too small; using append-only progress.\n' >&2
          refresh=false
          printf '    %s\n' "${frame[@]}"
          continue
        fi
        if (( previous_rows > 0 )); then
          printf '\033[%dF\033[J' "$previous_rows"
        fi
        limit=${#frame[@]}
        if [[ "$line" == __LAB_PROGRESS_FRAME__ ]] && (( rows > 4 && limit > rows - 3 )); then
          limit=$((rows - 4))
        fi
        previous_rows=0
        for ((index = 0; index < limit; index++)); do
          if [[ "$line" == __LAB_PROGRESS_FRAME__ ]] && (( columns > 5 )); then
            printf '    %s\n' "${frame[index]:0:columns-5}"
          else
            printf '    %s\n' "${frame[index]}"
          fi
          previous_rows=$((previous_rows + 1))
        done
        if (( limit < ${#frame[@]} )); then
          printf '%.*s\n' "$((columns > 1 ? columns - 1 : 1))" \
            '    More rows hidden; the full final table will be printed when monitoring ends.'
          previous_rows=$((previous_rows + 1))
        fi
        if [[ "$line" == __LAB_PROGRESS_DONE__ ]]; then
          previous_rows=0
        fi
      fi
    elif [[ "$refresh" == true && "$collecting" == true ]]; then
      frame+=("$line")
    elif [[ "$line" == __LAB_STEP__* ]]; then
      if [[ "$color" == true ]]; then
        printf '\033[1;36m%s\033[0m\n' "${line#__LAB_STEP__}"
      else
        printf '%s\n' "${line#__LAB_STEP__}"
      fi
    else
      printf '    %s\n' "$line"
    fi
  done
  if [[ "$refresh" == true ]]; then
    if (( previous_rows > 0 )); then
      printf '\033[%dF\033[J' "$previous_rows"
      printf '    %s\n' "${frame[@]}"
    elif [[ "$collecting" == true && ${#frame[@]} -gt 0 ]]; then
      printf '    %s\n' "${frame[@]}"
    fi
    exec {terminal_fd}>&-
  fi
}

# Only wrap executable scripts, not an interactive shell sourcing this helper.
if [[ "${BASH_SOURCE[1]:-${BASH_SOURCE[0]:-$0}}" == "$0" && "${LAB_LOG_SCRIPT:-}" != "$0" ]]; then
  lab_color=false
  if [[ -z "${NO_COLOR:-}" && ( -t 1 || "${FORCE_COLOR:-0}" == 1 ) ]]; then
    lab_color=true
  fi
  lab_started=$SECONDS
  printf 'Script: %s\nStarted: %s\n' "${0##*/}" "$(date '+%Y-%m-%d %H:%M:%S %z')"

  exec {lab_stdout}> >(lab_output "$lab_color")
  lab_stdout_pid=$!
  exec {lab_stderr}> >(lab_output "$lab_color" >&2)
  lab_stderr_pid=$!

  lab_finish() {
    local status="$1"
    local output_failed=false
    exec {lab_stdout}>&- {lab_stderr}>&-
    if ! wait "$lab_stdout_pid"; then
      output_failed=true
    fi
    if ! wait "$lab_stderr_pid"; then
      output_failed=true
    fi
    if [[ "$output_failed" == true ]]; then
      printf 'ERROR: Script output forwarding failed.\n' >&2
      if [[ "$status" == 0 ]]; then
        status=1
      fi
    fi
    local elapsed=$((SECONDS - lab_started))
    if [[ "$lab_color" == true ]]; then
      if [[ "$status" == 0 ]]; then
        printf '\033[1;32m'
      else
        printf '\033[1;31m'
      fi
    fi
    printf 'Ended: %s\nTotal elapsed: %02d:%02d:%02d (%ds)\nExit status: %d\n' \
      "$(date '+%Y-%m-%d %H:%M:%S %z')" \
      "$((elapsed / 3600))" "$((elapsed / 60 % 60))" "$((elapsed % 60))" \
      "$elapsed" "$status"
    if [[ "$lab_color" == true ]]; then
      printf '\033[0m'
    fi
    trap - EXIT
    exit "$status"
  }
  trap 'lab_finish "$?"' EXIT

  # Freeze the entry script so edits cannot shift a running Bash file's read position.
  lab_script="$(cat -- "$0")"
  if LAB_LOG_SCRIPT="$0" bash -c "$lab_script" "$0" "$@" >&"$lab_stdout" 2>&"$lab_stderr"; then
    exit 0
  else
    exit "$?"
  fi
fi

if [[ "${LAB_LOG_SCRIPT:-}" == "$0" ]]; then
  lab_step Setup "Load and validate lab configuration"
fi

# ── Load lab configuration and isolate local state ────────────────────────────
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/.env}"
[[ -f "$CONFIG_FILE" ]] || {
  echo "Copy .env.example to .env and configure it." >&2
  exit 1
}

set -a
# Strip Windows line endings before evaluating the trusted shell configuration.
# shellcheck source=/dev/null
source <(sed 's/\r$//' "$CONFIG_FILE")
set +a

export LOCATION="${LOCATION:-eastus2}"
export SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-agent-sa}"
export CHAT_PERSISTENCE_ENABLED="${CHAT_PERSISTENCE_ENABLED:-false}"
export IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-agent-host}"
export IMAGE_TAG="${IMAGE_TAG:-lab-v1}"
export FOUNDRY_LOCATION="${FOUNDRY_LOCATION:-westus3}"
export AMR_LOCATION="${AMR_LOCATION:-westus3}"
export FOUNDRY_PROJECT_NAME="${FOUNDRY_PROJECT_NAME:-sandbox-agent-prj}"
export LLM_MODEL="${LLM_MODEL:-gpt-5.4-mini}"
export MODEL_VERSION="${MODEL_VERSION:-2026-03-17}"
export MODEL_CAPACITY="${MODEL_CAPACITY:-50}"
export EMBEDDING_MODEL="${EMBEDDING_MODEL:-text-embedding-3-small}"
export EMBEDDING_MODEL_VERSION="${EMBEDDING_MODEL_VERSION:-1}"
export EMBEDDING_CAPACITY="${EMBEDDING_CAPACITY:-30}"
export SEMANTIC_CACHE_THRESHOLD="${SEMANTIC_CACHE_THRESHOLD:-0.05}"
export SEMANTIC_CACHE_TTL="${SEMANTIC_CACHE_TTL:-300}"
export APIM_PUBLISHER_EMAIL="${APIM_PUBLISHER_EMAIL:-admin@example.com}"
export APIM_PUBLISHER_NAME="${APIM_PUBLISHER_NAME:-AKS Agent Sandbox Lab}"

mkdir -p "$ROOT/.lab"
export KUBECONFIG="$HOME/.kube/config"
export PYTHONDONTWRITEBYTECODE=1

# ── Validate configuration and prerequisites ──────────────────────────────────
die() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null || die "Required tool missing: $1"
}

required() {
  [[ -n "${!1:-}" ]] || die "Set $1 in $CONFIG_FILE"
}

for name in RESOURCE_GROUP CLUSTER_NAME NODEPOOL_NAME NAMESPACE STORAGE_CONTAINER TIMEOUT; do
  required "$name"
done

export STORAGE_CONFIG="${NAMESPACE}-storage"
[[ "$NAMESPACE" =~ ^[a-z][a-z0-9-]{0,62}$ && "$NAMESPACE" != kube-* && "$NAMESPACE" != default ]] ||
  die "Use a dedicated non-system namespace."
[[ "$NODEPOOL_NAME" =~ ^[a-z][a-z0-9]{0,11}$ && "$NODEPOOL_NAME" != systempool ]] ||
  die "Use a lowercase User pool name of at most 12 characters, not systempool."
[[ "$TIMEOUT" =~ ^[1-9][0-9]*[smh]$ ]] || die "TIMEOUT must be a positive duration such as 10m."
TIMEOUT_SECONDS="${TIMEOUT%?}"
case "${TIMEOUT: -1}" in
  m) TIMEOUT_SECONDS=$((TIMEOUT_SECONDS * 60)) ;;
  h) TIMEOUT_SECONDS=$((TIMEOUT_SECONDS * 3600)) ;;
esac
[[ "$SERVICE_ACCOUNT" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || die "Use a valid dedicated ServiceAccount name."
[[ "$STORAGE_CONTAINER" != data ]] || die "Snapshots must use a separate container from data."
[[ "$CHAT_PERSISTENCE_ENABLED" == true || "$CHAT_PERSISTENCE_ENABLED" == false ]] ||
  die "CHAT_PERSISTENCE_ENABLED must be true or false."

require az
require python3

azure_cli_details="$(command az --version </dev/null)" ||
  die "Could not inspect Azure CLI: $azure_cli_details"
WINDOWS_AZ=false
if [[ "$azure_cli_details" == *"Python (Windows)"* ]]; then
  require wslpath
  WINDOWS_AZ=true
  # Normalize captured Windows output while preserving pipeline failures.
  az() {
    command az "$@" | tr -d '\r'
  }
fi

# Use the compiler managed by the selected CLI, whether Linux or Windows.
export AZURE_BICEP_USE_BINARY_FROM_PATH=false

kata_feature_state() {
  az feature show \
    --namespace Microsoft.ContainerService \
    --name KataVMIsolationV2Preview \
    --query properties.state \
    -o tsv
}

wait_for_azure_operation() {
  local label="$1"
  local state_command="$2"
  local progress_command="$3"
  local failure_command="${4:-:}"
  local refresh="${5:-false}"
  local started=$SECONDS
  local started_at
  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local state
  while true; do
    state="$("$state_command")"
    if [[ "$refresh" == true ]]; then
      echo "__LAB_PROGRESS_BEGIN__"
    fi
    echo "[$(date '+%H:%M:%S')] $label: $state (elapsed $((SECONDS - started))s)"
    "$progress_command"
    if [[ "$refresh" == true ]]; then
      echo "__LAB_PROGRESS_FRAME__"
    fi
    case "$state" in
      Succeeded|Registered)
        if [[ "$refresh" == true ]]; then
          echo "__LAB_PROGRESS_DONE__"
        fi
        return 0
        ;;
      Failed|Canceled)
        if [[ "$refresh" == true ]]; then
          echo "__LAB_PROGRESS_DONE__"
        fi
        if ! "$failure_command" "$started_at"; then
          echo "ERROR: Could not retrieve failure diagnostics; inspect Azure Activity Log manually." >&2
        fi
        die "$label ended with $state; inspect Azure operation details before continuing."
        ;;
      Accepted|Running|Creating|Updating|Canceling|Registering|NotRegistered|Unregistered)
        sleep 30
        ;;
      *)
        if [[ "$refresh" == true ]]; then
          echo "__LAB_PROGRESS_DONE__"
        fi
        die "Unexpected $label state '$state'; inspect Azure before continuing."
        ;;
    esac
  done
}

ensure_kata_v2_feature() {
  local feature_state
  echo "Checking subscription preview feature KataVMIsolationV2Preview..."
  feature_state="$(kata_feature_state)"
  case "$feature_state" in
    Registered|Registering) ;;
    NotRegistered|Unregistered)
      echo "Registering KataVMIsolationV2Preview before creating any Kata nodes..."
      az feature register \
        --namespace Microsoft.ContainerService \
        --name KataVMIsolationV2Preview \
        --output none
      ;;
    *) die "KataVMIsolationV2Preview is '$feature_state'; complete feature registration/approval before provisioning." ;;
  esac
  wait_for_azure_operation "Kata v2 preview registration" kata_feature_state :
}

aks_state() {
  az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
    --query provisioningState -o tsv
}

aks_progress() {
  az aks nodepool list -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" \
    --query '[].{Pool:name,State:provisioningState,Nodes:count,Runtime:workloadRuntime}' \
    -o table
}

aks_failure_details() {
  local since="$1"
  local pool_name="${2:-}"
  local subscription_id
  local failures
  local resource_id
  subscription_id="$(az account show --query id -o tsv)" || return "$?"
  [[ -n "$subscription_id" ]] || {
    echo "ERROR: No active subscription ID for AKS failure diagnostics." >&2
    return 1
  }
  resource_id="/subscriptions/$subscription_id/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$CLUSTER_NAME"
  if [[ -n "$pool_name" ]]; then
    resource_id="$resource_id/agentPools/$pool_name"
  fi
  echo "Azure Activity Log failure details for $resource_id since $since:"
  failures="$(az monitor activity-log list \
    --resource-id "$resource_id" \
    --start-time "$since" \
    --max-events 20 \
    --query "[?status.value=='Failed'].{time:eventTimestamp,correlationId:correlationId,error:properties.statusMessage}" \
    -o json)" || return "$?"
  python3 - "$failures" <<'PY'
import json
import sys

records = json.loads(sys.argv[1])
if not records:
    print("No failed activity record returned in this operation window; the log can lag. Inspect Azure Activity Log or the latest AKS operation manually.")
for record in records:
    print(f'Time: {record.get("time")}; correlation ID: {record.get("correlationId")}')
    message = record.get("error")
    if isinstance(message, str):
        try:
            message = json.loads(message)
        except json.JSONDecodeError:
            print("Azure status message is plain text:")
            print(message)
            continue
    if message is None:
        print("The failed activity record contains no status message; inspect the latest AKS operation.")
    else:
        print(json.dumps(message, ensure_ascii=False, indent=2))
PY
}

# ── Image, cluster connection and deployment outputs ──────────────────────────
check_image() {
  [[ -s "$ROOT/.lab/image.json" ]] || die "No built image recorded. Run provisioning (or scripts/build-image.sh) first."
  required ACR_LOGIN_SERVER
  WORKLOAD_IMAGE="$(python3 - "$ROOT/.lab/image.json" <<'PY'
import json
import os
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    record = json.load(source)
assert record["resource_group"] == os.environ["RESOURCE_GROUP"], "Image belongs to another resource group"
assert record["cluster"] == os.environ["CLUSTER_NAME"], "Image belongs to another cluster"
image = record["image"]
prefix = os.environ["ACR_LOGIN_SERVER"] + "/" + os.environ["IMAGE_REPOSITORY"] + "@"
assert image.startswith(prefix), "Image must come from this lab's ACR and repository"
assert re.fullmatch(r"sha256:[a-f0-9]{64}", image[len(prefix):]), "Image digest is invalid"
print(image)
PY
)"
  export WORKLOAD_IMAGE
}

connect() {
  require kubectl
  local credential_file="$KUBECONFIG"
  mkdir -p "$(dirname -- "$KUBECONFIG")"
  if [[ "$WINDOWS_AZ" == true ]]; then
    credential_file="$(wslpath -w "$KUBECONFIG")"
  fi
  echo "Retrieving Kubernetes credentials for $CLUSTER_NAME into $KUBECONFIG..."
  az aks get-credentials \
    -g "$RESOURCE_GROUP" \
    -n "$CLUSTER_NAME" \
    --file "$credential_file" \
    --overwrite-existing \
    --only-show-errors
}

load_outputs() {
  echo "Loading agent-sandbox-lab deployment outputs from $RESOURCE_GROUP..."
  az deployment group show \
    -g "$RESOURCE_GROUP" \
    -n agent-sandbox-lab \
    --query properties.outputs \
    -o json > "$ROOT/.lab/outputs.json"

  output_value() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["value"])' \
      "$ROOT/.lab/outputs.json" "$1"
  }

  STORAGE_ACCOUNT="$(output_value storageAccount)"
  BROKER_CLIENT_ID="$(output_value brokerClientId)"
  TENANT_ID="$(output_value tenantId)"
  ACR_NAME="$(output_value acrName)"
  ACR_LOGIN_SERVER="$(output_value acrLoginServer)"
  KUBELET_CLIENT_ID="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
    --query identityProfile.kubeletidentity.clientId -o tsv)"
  [[ -n "$KUBELET_CLIENT_ID" ]] || die "The current AKS cluster has no kubelet client ID."
  AGENT_CLIENT_ID="$(output_value agentClientId)"
  APIM_GATEWAY_URL="$(output_value apimGatewayUrl)"
  LLM_MODEL="$(output_value modelDeploymentName)"
  export STORAGE_ACCOUNT BROKER_CLIENT_ID TENANT_ID ACR_NAME ACR_LOGIN_SERVER
  export KUBELET_CLIENT_ID AGENT_CLIENT_ID APIM_GATEWAY_URL LLM_MODEL
}

# ── Manifest rendering and session access ─────────────────────────────────────
render() {
  require envsubst
  envsubst '${NAMESPACE} ${NODEPOOL_NAME} ${WORKLOAD_IMAGE} ${STORAGE_ACCOUNT} ${STORAGE_CONTAINER} ${STORAGE_CONFIG} ${SNAPSHOT_NAME} ${SOURCE_POD} ${RESOURCE_GROUP} ${SERVICE_ACCOUNT} ${KUBELET_CLIENT_ID} ${AGENT_CLIENT_ID} ${TENANT_ID} ${APIM_GATEWAY_URL} ${LLM_MODEL} ${CHAT_PERSISTENCE_ENABLED}' \
    < "$ROOT/manifests/$1"
}

session_pod() {
  kubectl -n "$NAMESPACE" get pods -l app=agent-session -o json |
    python3 -c 'import json,sys; p=json.load(sys.stdin)["items"]; assert len(p)==1, "Expected exactly one session pod"; print(p[0]["metadata"]["name"])'
}

request() {
  kubectl -n "$NAMESPACE" exec "$1" -- python -c \
    'import urllib.request,sys; print(urllib.request.urlopen("http://127.0.0.1:8080"+sys.argv[1],timeout=5).read().decode())' "$2"
}

wait_session() {
  kubectl -n "$NAMESPACE" wait \
    --for=condition=Ready sandbox/agent-session \
    --timeout="$TIMEOUT"
  kubectl -n "$NAMESPACE" wait \
    --for=condition=Ready pod \
    -l app=agent-session \
    --timeout="$TIMEOUT"
}
