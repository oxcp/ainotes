#!/usr/bin/env bash
# 01-provision.sh — Provision the dedicated AKS Agent Sandbox lab infrastructure
#
# Usage: bash scripts/01-provision.sh
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: Azure login, resource/role assignment permissions, and a new group.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/6] Validate configuration and Azure CLI compatibility ───────────────────
lab_step 1/6 "Validate configuration and Azure CLI compatibility"
for name in LOCATION KUBERNETES_VERSION VM_SIZE SYSTEM_NODE_COUNT KATA_NODE_COUNT; do
  required "$name"
done
[[ "$APIM_PUBLISHER_EMAIL" == *@*.* ]] || die "Set a valid APIM publisher email."
[[ "$MODEL_CAPACITY" =~ ^[1-9][0-9]*$ ]] || die "MODEL_CAPACITY must be a positive integer."
[[ "$EMBEDDING_CAPACITY" =~ ^[1-9][0-9]*$ ]] || die "EMBEDDING_CAPACITY must be a positive integer."
[[ "$SEMANTIC_CACHE_TTL" =~ ^[1-9][0-9]*$ ]] || die "SEMANTIC_CACHE_TTL must be a positive integer."
[[ "$EMBEDDING_MODEL" != "$LLM_MODEL" ]] || die "Chat and embedding deployments must have different names."
python3 - "$SEMANTIC_CACHE_THRESHOLD" <<'PY'
import re
import sys

value = sys.argv[1]
assert re.fullmatch(r"(0(?:\.[0-9]+)?|1(?:\.0+)?)", value), "SEMANTIC_CACHE_THRESHOLD must be a number from 0 to 1"
PY
[[ "$IMAGE_REPOSITORY" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || die "Use a lowercase ACR image repository."
[[ "$IMAGE_TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || die "Invalid image tag."

python3 - "$SYSTEM_NODE_COUNT" "$KATA_NODE_COUNT" <<'PY'
import sys
assert all(int(n) >= 2 for n in sys.argv[1:]), "Both pools require at least two nodes"
PY

az version -o json | python3 -c \
  'import json,sys; v=json.load(sys.stdin)["azure-cli"]; assert tuple(map(int,v.split(".")[:3])) >= (2,86,0), "Azure CLI 2.86.0+ required for managed Gateway API and application routing"'
echo "Compiling the infrastructure template with Azure CLI-managed Bicep before creating resources..."
(
  cd "$ROOT"
  az bicep build --file infra/main.bicep --stdout >/dev/null
)
az account show --query '{subscription:name,tenant:tenantId}' -o table

# ── Show real resource state while Azure operations are in progress ──────────
deployment_state() {
  az deployment group show -g "$RESOURCE_GROUP" -n agent-sandbox-lab \
    --query properties.provisioningState -o tsv
}

deployment_progress() {
  local deployments
  local deployment
  local state
  deployments="$(az deployment group list -g "$RESOURCE_GROUP" \
    --query "[?name=='agent-sandbox-lab' || name=='sandbox-ai-gateway'].[name,properties.provisioningState]" \
    -o tsv)"
  while IFS=$'\t' read -r deployment state; do
    [[ -n "$deployment" ]] || continue
    echo "Deployment $deployment: $state"
    az deployment operation group list -g "$RESOURCE_GROUP" -n "$deployment" \
      --query '[?properties.targetResource.resourceName!=`null`].{Resource:properties.targetResource.resourceName,Type:properties.targetResource.resourceType,State:properties.provisioningState}' \
      -o table
    if [[ "$state" == Failed ]]; then
      az deployment group show -g "$RESOURCE_GROUP" -n "$deployment" \
        --query properties.error -o json
    fi
  done <<< "$deployments"
}

# ── [2/6] Require a new group and register deployment dependencies ─────────────
lab_step 2/6 "Require a new group and register deployment dependencies"
echo "Provisioning a dedicated paid lab in $RESOURCE_GROUP ($LOCATION)."
[[ "$(az group exists -n "$RESOURCE_GROUP")" == false ]] ||
  die "Resource group already exists; choose an unused group. This lab never adopts shared groups."

ensure_kata_v2_feature

# Refresh ContainerService after the feature is Registered so new pools receive v2.
for provider in Microsoft.ContainerService Microsoft.KubernetesConfiguration Microsoft.Storage Microsoft.ManagedIdentity Microsoft.Network Microsoft.ContainerRegistry Microsoft.CognitiveServices Microsoft.ApiManagement Microsoft.Cache; do
  echo "Registering provider $provider..."
  az provider register --namespace "$provider" --wait
done

az extension add --name k8s-extension --upgrade --only-show-errors

# ── [3/6] Create the dedicated group and deploy infrastructure ──────────────────
lab_step 3/6 "Create the dedicated group and deploy infrastructure"
echo "Creating resource group $RESOURCE_GROUP in $LOCATION..."
az group create \
  -n "$RESOURCE_GROUP" \
  -l "$LOCATION" \
  --tags purpose=aks-agent-sandbox-lab \
  --output none

echo "Submitting Bicep deployment agent-sandbox-lab; resource states will refresh every 30 seconds."
(
  cd "$ROOT"
  az deployment group create \
    -g "$RESOURCE_GROUP" \
    -n agent-sandbox-lab \
    --template-file infra/main.bicep \
    --parameters \
      location="$LOCATION" \
      clusterName="$CLUSTER_NAME" \
      kubernetesVersion="$KUBERNETES_VERSION" \
      nodePoolName="$NODEPOOL_NAME" \
      vmSize="$VM_SIZE" \
      systemNodeCount="$SYSTEM_NODE_COUNT" \
      kataNodeCount="$KATA_NODE_COUNT" \
      storageContainer="$STORAGE_CONTAINER" \
      namespace="$NAMESPACE" \
      serviceAccountName="$SERVICE_ACCOUNT" \
      foundryLocation="$FOUNDRY_LOCATION" \
      amrLocation="$AMR_LOCATION" \
      projectName="$FOUNDRY_PROJECT_NAME" \
      modelName="$LLM_MODEL" \
      modelDeploymentName="$LLM_MODEL" \
      modelVersion="$MODEL_VERSION" \
      modelCapacity="$MODEL_CAPACITY" \
      embeddingModelName="$EMBEDDING_MODEL" \
      embeddingDeploymentName="$EMBEDDING_MODEL" \
      embeddingModelVersion="$EMBEDDING_MODEL_VERSION" \
      embeddingCapacity="$EMBEDDING_CAPACITY" \
      semanticCacheThreshold="$SEMANTIC_CACHE_THRESHOLD" \
      semanticCacheTtl="$SEMANTIC_CACHE_TTL" \
      apimPublisherEmail="$APIM_PUBLISHER_EMAIL" \
      apimPublisherName="$APIM_PUBLISHER_NAME" \
    --no-wait \
    --output none
)
wait_for_azure_operation "Infrastructure deployment" deployment_state deployment_progress : true

# ── [4/6] Reconcile the Kata pool and load cluster access ──────────────────────
lab_step 4/6 "Reconcile the Kata pool and load cluster access"
echo "Reconciling AKS configuration (confirmation handled with --yes); this may take several minutes."
az aks update \
  -g "$RESOURCE_GROUP" \
  -n "$CLUSTER_NAME" \
  --yes \
  --no-wait \
  --output none
wait_for_azure_operation "AKS reconciliation" aks_state aks_progress aks_failure_details
load_outputs
connect

# ── [5/6] Build and publish the chat agent image with ACR Tasks ────────────────
lab_step 5/6 "Build and publish the chat agent image with ACR Tasks"
bash "$ROOT/scripts/build-image.sh"

# ── [6/6] Verify runtime support before extension installation ─────────────────
lab_step 6/6 "Verify runtime support before extension installation"
bash "$ROOT/scripts/02-verify-runtime.sh"
