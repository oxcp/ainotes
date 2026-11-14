#!/usr/bin/env bash
# build-images.sh -- Module 6: build five Agent images using ACR Tasks.
#
#   1. Validate inputs and resolve the existing Module 1 registry
#   2. Check each Agent Dockerfile
#   3. Build and publish sequentially; stop on the first failure
#
# Usage: bash build-images.sh [--registry ACR_NAME] [--tag TAG]
# Env overrides: ACR_NAME, IMAGE_TAG, SUBSCRIPTION_ID, RESOURCE_GROUP, DEPLOYMENT_SN.
# Prerequisites: Module 1 deployed; az installed; no local Docker required.

set -euo pipefail
set +x
umask 077

# -- Helpers and command-line options ----------------------------------------
usage() {
  cat <<'USAGE'
Usage: bash build-images.sh [--registry ACR_NAME] [--tag TAG]

Build and publish five Agent images remotely using ACR Tasks (az acr build).
  --registry ACR_NAME  ACR_NAME; otherwise acragenthost<DEPLOYMENT_SN or RG deploymentSN tag>.
  --tag TAG            IMAGE_TAG or latest (Module-04 convention).
  --help               Show this help.

Run az login and select the intended subscription before invoking this script.
Builds upload the local context and publish images to the existing ACR.
No local Docker daemon or named persistent Task is required.
This script does not create registries or deploy AKS/ACA resources.
Explicit flags override environment variables. RESOURCE_GROUP defaults to rg-agenthost-workshop.
SUBSCRIPTION_ID defaults to the current Azure CLI account.
USAGE
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

# -- Configuration ----------------------------------------------------------
images_preflight() {
  registry="${ACR_NAME:-}"
  tag="${IMAGE_TAG:-latest}"
  while (($#)); do
    case "$1" in
      --registry | --tag)
        if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
          fail "$1 requires a value."
        fi
        if [[ "$1" == --registry ]]; then
          registry="$2"
        else
          tag="$2"
        fi
        shift 2
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1. Use --help for usage."
        ;;
    esac
  done
  for key in registry tag; do
    value="${!key}"
    value="${value//$'\r'/}"
    printf -v "$key" '%s' "${value//$'\n'/}"
  done

  # -- Validate inputs and resolve the existing registry -----------------------
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail "Invalid image tag."
  command -v az >/dev/null 2>&1 || fail "Azure CLI is required."
  subscription_args=()
  if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
    subscription_args=(--subscription "$(printf '%s' "$SUBSCRIPTION_ID" | tr -d '\r\n')")
  fi
  if [[ -z "$registry" ]]; then
    resource_group="$(printf '%s' "${RESOURCE_GROUP:-rg-agenthost-workshop}" | tr -d '\r\n')"
    sn="${DEPLOYMENT_SN:-$(az group show "${subscription_args[@]}" --resource-group "$resource_group" --query tags.deploymentSN -o tsv | tr -d '\r\n')}"
    sn="$(printf '%s' "$sn" | tr -d '\r\n')"
    [[ "$sn" =~ ^[a-z0-9]+$ ]] || fail "Set DEPLOYMENT_SN or ensure the existing RG has its Module-01 deploymentSN tag."
    registry="acragenthost$sn"
  fi
  [[ "$registry" =~ ^[a-z0-9]{5,50}$ ]] || fail "Use the existing ACR name (5-50 lowercase letters/digits), not a URL or login server."
  root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/agent-src" && pwd)"
  # The left name is used in image tags and ACA roles; the right name is the Python package directory.
  agents=(
    "chat:chat_agent"
    "orchestrator:orchestrator_agent"
    "data-processing:data_processing_agent"
    "rag:rag_agent"
    "sql:sql_agent"
  )
  for entry in "${agents[@]}"; do
    [[ -f "$root/${entry#*:}/Dockerfile" ]] || fail "Dockerfile missing for ${entry%%:*}."
  done
}

# Sourcing exposes only the read-only guard for deploy.sh; it never submits builds.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi
echo "  ==> [1/2] Validating image settings and all five Dockerfiles"
images_preflight "$@"

# -- Build each Agent image after all Dockerfiles pass preflight --------------
echo "  ==> [2/2] Building and publishing five Agent images in the existing ACR"
for entry in "${agents[@]}"; do
  role="${entry%%:*}"
  package="${entry#*:}"
  image="studio-$role:$tag"
  printf '    Building and publishing %s in ACR %s\n' "$image" "$registry"
  # Use agent-src as the context so every Dockerfile can COPY shared code as well as its own package.
  # Deployment credentials live in module-06/.local, outside this uploaded context.
  if ! az acr build \
    --registry "$registry" \
    --image "$image" \
    --file "$root/$package/Dockerfile" \
    --platform linux \
    "$root" \
    "${subscription_args[@]}"; then
    fail "ACR build failed for $role; later images were not submitted."
  fi
done

printf 'Built and published all five Agent images in ACR %s.\n' "$registry"
