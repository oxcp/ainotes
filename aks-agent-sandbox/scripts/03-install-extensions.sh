#!/usr/bin/env bash
# 03-install-extensions.sh — Install and verify Agent Sandbox and Pod Snapshot
#
# Usage: bash scripts/03-install-extensions.sh
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: verified Kata v2 runtime and provisioned broker/storage outputs.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/5] Verify runtime support and load broker/storage configuration ──────────
lab_step 1/5 "Verify runtime support and load broker/storage configuration"
bash "$ROOT/scripts/02-verify-runtime.sh"
load_outputs

# ── [2/5] Install the managed extensions with scoped storage access ─────────────
lab_step 2/5 "Install the managed extensions with scoped storage access"
extension_state() {
  az k8s-extension show \
    -g "$RESOURCE_GROUP" \
    --cluster-name "$CLUSTER_NAME" \
    --cluster-type managedClusters \
    --name "$extension" \
    --query provisioningState -o tsv
}

extension_progress() {
  echo "Kubernetes components in $extension-system (no resources means deployment has not reached this stage):"
  kubectl -n "$extension-system" get deployments,daemonsets,pods \
    --request-timeout=30s -o wide
}

extension_failure_details() {
  az k8s-extension show \
    -g "$RESOURCE_GROUP" \
    --cluster-name "$CLUSTER_NAME" \
    --cluster-type managedClusters \
    --name "$extension" \
    --query '{error:errorInfo,statuses:statuses}' -o json
}

extension=agent-sandbox
echo "Submitting Agent Sandbox installation (1/2); Azure installation can take tens of minutes."
az k8s-extension create \
  -g "$RESOURCE_GROUP" \
  --cluster-name "$CLUSTER_NAME" \
  --cluster-type managedClusters \
  --name agent-sandbox \
  --extension-type Microsoft.AgentSandbox \
  --no-wait \
  --output none
wait_for_azure_operation "Extension $extension installation" \
  extension_state extension_progress extension_failure_details true

extension=pod-snapshot
echo "Submitting Pod Snapshot installation (2/2) with scoped broker storage and Kata-pool workers."
az k8s-extension create \
  -g "$RESOURCE_GROUP" \
  --cluster-name "$CLUSTER_NAME" \
  --cluster-type managedClusters \
  --name pod-snapshot \
  --extension-type Microsoft.PodSnapshot \
  --configuration-settings \
    "broker.storageAccount=$STORAGE_ACCOUNT" \
    "azureBlob.workloadIdentity.clientID=$BROKER_CLIENT_ID" \
    "azureBlob.workloadIdentity.tenantID=$TENANT_ID" \
    "nodeWorker.nodeSelector.kubernetes\\.azure\\.com/agentpool=$NODEPOOL_NAME" \
  --no-wait \
  --output none
wait_for_azure_operation "Extension $extension installation" \
  extension_state extension_progress extension_failure_details true

# ── [3/5] Check extension provisioning and minimum supported versions ──────────
lab_step 3/5 "Check extension provisioning and minimum supported versions"
for extension in agent-sandbox pod-snapshot; do
  echo "Checking extension $extension..."
  az k8s-extension show \
    -g "$RESOURCE_GROUP" \
    --cluster-name "$CLUSTER_NAME" \
    --cluster-type managedClusters \
    --name "$extension" \
    -o json |
    python3 -c '
import json,sys
p=json.load(sys.stdin)
minimum=(1,0,7) if sys.argv[1]=="agent-sandbox" else (0,1,1)
assert p["provisioningState"]=="Succeeded", p["provisioningState"]
assert tuple(map(int,p["currentVersion"].split(".")))>=minimum, "Extension too old"
print(sys.argv[1],p["currentVersion"],p["provisioningState"])
' "$extension"
done

# ── [4/5] Wait for controllers and require worker coverage on every Kata node ───
lab_step 4/5 "Wait for controllers and require worker coverage on every Kata node"
kubectl -n agent-sandbox-system rollout status \
  deployment/agent-sandbox-controller \
  --timeout="$TIMEOUT"
kubectl -n pod-snapshot-system rollout status \
  deployment/pod-snapshot-manager \
  deployment/pod-snapshot-broker \
  daemonset/pod-snapshot-node-worker \
  --timeout="$TIMEOUT"

expected="$(az aks nodepool show -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" -n "$NODEPOOL_NAME" --query count -o tsv)"
kubectl -n pod-snapshot-system get daemonset pod-snapshot-node-worker -o json |
  python3 -c 'import json,sys; s=json.load(sys.stdin)["status"]; n=int(sys.argv[1]); assert s["desiredNumberScheduled"]==n and s.get("numberReady",0)==n, "Worker coverage mismatch"' "$expected"

# ── [5/5] Verify the installed APIs ────────────────────────────────────────────
lab_step 5/5 "Verify the installed APIs"
kubectl get crd \
  sandboxes.agents.x-k8s.io \
  sandboxtemplates.extensions.agents.x-k8s.io \
  sandboxwarmpools.extensions.agents.x-k8s.io \
  sandboxclaims.extensions.agents.x-k8s.io \
  podsnapshots.podsnapshot.aks.azure.com
kubectl explain sandboxclaims.spec.warmPoolRef --api-version=extensions.agents.x-k8s.io/v1beta1

echo "Extensions ready. If broker storage access fails, allow Azure RBAC propagation and inspect broker logs."
