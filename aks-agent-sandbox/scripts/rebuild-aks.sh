#!/usr/bin/env bash
# rebuild-aks.sh - Recreate only the lab AKS cluster and its Kata pool
#
# Usage: bash scripts/rebuild-aks.sh --confirm-cluster <cluster-name>
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: original lab deployment, Azure login, AKS/identity/RBAC permissions.
# WARNING: destroys all cluster workloads, extensions and in-memory sessions.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/7] Confirm the target and validate retained lab infrastructure ──────────
lab_step 1/7 "Confirm the target and validate retained lab infrastructure"
[[ $# == 2 && "$1" == --confirm-cluster && "$2" == "$CLUSTER_NAME" ]] ||
  die "Deletes AKS and ALL its workloads. Usage: bash scripts/rebuild-aks.sh --confirm-cluster $CLUSTER_NAME"
for name in LOCATION KUBERNETES_VERSION VM_SIZE SYSTEM_NODE_COUNT KATA_NODE_COUNT; do
  required "$name"
done
require kubectl
python3 - "$KUBERNETES_VERSION" "$VM_SIZE" "$SYSTEM_NODE_COUNT" "$KATA_NODE_COUNT" <<'PY'
import re
import sys

version, sku, *counts = sys.argv[1:]
assert re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version), "Use a numeric Kubernetes version"
assert tuple(map(int, version.split(".")[:2])) >= (1, 35), "Kubernetes 1.35+ required"
assert re.fullmatch(r"Standard_(?:D\d+(?:as|ads|als|alds)|E\d+(?:as|ads)|F\d+(?:als|as|ams))_v6", sku), "Unsupported v6 VM family"
assert all(re.fullmatch(r"[1-9]\d*", count) and int(count) >= 2 for count in counts), "Both pools require at least two nodes"
PY
az version -o json | python3 -c \
  'import json,sys; v=json.load(sys.stdin)["azure-cli"]; assert tuple(map(int,v.split(".")[:3])) >= (2,86,0), "Azure CLI 2.86.0+ required for managed Gateway API and application routing"'
[[ "$(az group show -n "$RESOURCE_GROUP" --query tags.purpose -o tsv)" == aks-agent-sandbox-lab ]] ||
  die "Resource group is not tagged as a dedicated lab; refusing deletion."
subscription_id="$(az account show --query id -o tsv)"
expected_cluster_id="/subscriptions/$subscription_id/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$CLUSTER_NAME"
deployment_cluster_id="$(az deployment group show -g "$RESOURCE_GROUP" -n agent-sandbox-lab \
  --query properties.outputs.clusterId.value -o tsv)"
[[ "${deployment_cluster_id,,}" == "${expected_cluster_id,,}" ]] ||
  die "Original deployment does not identify this cluster in the active subscription."
clusters="$(az aks list -g "$RESOURCE_GROUP" --query '[].name' -o tsv)"
[[ -z "$clusters" || "$clusters" == "$CLUSTER_NAME" ]] ||
  die "Unexpected clusters in resource group; inspect manually."
control_plane_id="$(az identity show -g "$RESOURCE_GROUP" -n "${CLUSTER_NAME}-control-plane" \
  --query id -o tsv)"
expected_identity_id="/subscriptions/$subscription_id/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-control-plane"
[[ "${control_plane_id,,}" == "${expected_identity_id,,}" ]] ||
  die "Control-plane identity is not the original lab identity."
subnet_id="$(az network vnet subnet show -g "$RESOURCE_GROUP" \
  --vnet-name sboxvnet -n aks-subnet --query id -o tsv)"
expected_subnet_id="/subscriptions/$subscription_id/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/sboxvnet/subnets/aks-subnet"
[[ "${subnet_id,,}" == "${expected_subnet_id,,}" ]] ||
  die "Subnet is not the original lab AKS subnet."
vnet_location="$(az network vnet show -g "$RESOURCE_GROUP" -n sboxvnet --query location -o tsv)"
[[ "${vnet_location,,}" == "${LOCATION,,}" ]] ||
  die "LOCATION must match the retained lab VNet region."
node_resource_group="MC_${RESOURCE_GROUP}_${CLUSTER_NAME}_${LOCATION}"
if [[ -n "$clusters" ]]; then
  node_resource_group="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
    --query nodeResourceGroup -o tsv)"
fi
[[ -n "$node_resource_group" && "${node_resource_group,,}" != "${RESOURCE_GROUP,,}" ]] ||
  die "AKS-managed node resource group is missing or equals the retained lab group."
for binding in agent snapshot-broker; do
  az identity show -g "$RESOURCE_GROUP" -n "${CLUSTER_NAME}-$binding" \
    --query id -o tsv
done
az identity federated-credential show -g "$RESOURCE_GROUP" \
  --identity-name "${CLUSTER_NAME}-agent" --name sandbox-agent --output none
az identity federated-credential show -g "$RESOURCE_GROUP" \
  --identity-name "${CLUSTER_NAME}-snapshot-broker" --name pod-snapshot-broker --output none
acr_name="$(az deployment group show -g "$RESOURCE_GROUP" -n agent-sandbox-lab \
  --query properties.outputs.acrName.value -o tsv)"
storage_account="$(az deployment group show -g "$RESOURCE_GROUP" -n agent-sandbox-lab \
  --query properties.outputs.storageAccount.value -o tsv)"
[[ -n "$acr_name" && -n "$storage_account" ]] || die "Original ACR/storage outputs are missing."
az acr show -g "$RESOURCE_GROUP" -n "$acr_name" --query id -o tsv
az storage account show -g "$RESOURCE_GROUP" -n "$storage_account" --query id -o tsv
echo "Target: $expected_cluster_id"
echo "WARNING: all AKS workloads, extensions and in-memory sessions will be lost."
echo "Foundry, APIM, ACR/images, Blob data, VNet and lab identities will be retained."

# ── [2/7] Register prerequisites before deleting the old cluster ───────────────
lab_step 2/7 "Register prerequisites before deleting the old cluster"
ensure_kata_v2_feature
for provider in Microsoft.ContainerService Microsoft.ManagedIdentity Microsoft.Network Microsoft.ContainerRegistry Microsoft.Storage; do
  echo "Refreshing provider $provider..."
  az provider register --namespace "$provider" --wait
done
(
  cd "$ROOT"
  az bicep build --file infra/kubelet-rbac.bicep --stdout >/dev/null
)

# ── [3/7] Delete only the confirmed cluster and wait for name release ──────────
lab_step 3/7 "Delete only the confirmed cluster and wait for name release"
if [[ -n "$clusters" ]]; then
  echo "Submitting deletion of $CLUSTER_NAME and its AKS-managed node resource group..."
  az aks delete -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --yes --no-wait
else
  echo "Cluster is already absent; continuing the confirmed rebuild."
fi
started=$SECONDS
while true; do
  state="$(az aks list -g "$RESOURCE_GROUP" \
    --query "[?name=='$CLUSTER_NAME'].provisioningState" -o tsv)"
  [[ -n "$state" ]] || break
  echo "[$(date '+%H:%M:%S')] AKS deletion: $state (elapsed $((SECONDS - started))s)"
  case "$state" in
    Failed|Canceled) die "AKS deletion ended with $state; refusing recreation." ;;
    Succeeded|Deleting|Accepted|Updating|Creating) sleep 30 ;;
    *) die "Unexpected AKS deletion state '$state'; inspect Azure before continuing." ;;
  esac
done
while true; do
  group_exists="$(az group exists -n "$node_resource_group")"
  case "$group_exists" in
    false) break ;;
    true)
      echo "[$(date '+%H:%M:%S')] Waiting for AKS-managed group $node_resource_group deletion (elapsed $((SECONDS - started))s)"
      sleep 30
      ;;
    *) die "Unexpected node resource group existence result '$group_exists'." ;;
  esac
done
rm -f -- \
  "$ROOT/.lab/snapshot-name" \
  "$ROOT/.lab/before.json" \
  "$ROOT/.lab/after.json" \
  "$ROOT/.lab/session-source.json" \
  "$ROOT/.lab/session-restore.yaml" \
  "$ROOT/.lab/warm-pool.yaml" \
  "$ROOT/.lab/pool.json"

# ── [4/7] Recreate AKS with the original network and control-plane identity ─────
lab_step 4/7 "Recreate AKS with the original network and control-plane identity"
az aks create \
  -g "$RESOURCE_GROUP" \
  -n "$CLUSTER_NAME" \
  --location "$LOCATION" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --dns-name-prefix "$CLUSTER_NAME" \
  --tier free \
  --enable-managed-identity \
  --assign-identity "$control_plane_id" \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-blob-driver \
  --enable-gateway-api \
  --enable-app-routing-istio \
  --nodepool-name systempool \
  --node-count "$SYSTEM_NODE_COUNT" \
  --node-vm-size "$VM_SIZE" \
  --os-sku AzureLinux \
  --vm-set-type VirtualMachineScaleSets \
  --node-osdisk-type Managed \
  --vnet-subnet-id "$subnet_id" \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --pod-cidr 10.42.0.0/16 \
  --service-cidr 10.41.0.0/16 \
  --dns-service-ip 10.41.0.10 \
  --load-balancer-sku standard \
  --outbound-type loadBalancer \
  --tags purpose=aks-agent-sandbox-lab \
  --no-ssh-key \
  --no-wait \
  --output none
wait_for_azure_operation "AKS creation" aks_state aks_progress aks_failure_details

# ── [5/7] Create the Kata pool and reconcile cluster configuration ─────────────
lab_step 5/7 "Create the Kata pool and reconcile cluster configuration"
az aks nodepool add \
  -g "$RESOURCE_GROUP" \
  --cluster-name "$CLUSTER_NAME" \
  --name "$NODEPOOL_NAME" \
  --mode User \
  --node-count "$KATA_NODE_COUNT" \
  --node-vm-size "$VM_SIZE" \
  --os-type Linux \
  --os-sku AzureLinux \
  --vm-set-type VirtualMachineScaleSets \
  --node-osdisk-type Managed \
  --workload-runtime KataVmIsolation \
  --vnet-subnet-id "$subnet_id" \
  --no-wait \
  --output none
pool_state() {
  az aks nodepool show -g "$RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" \
    -n "$NODEPOOL_NAME" --query provisioningState -o tsv
}
pool_failure_details() {
  aks_failure_details "$1" "$NODEPOOL_NAME"
}
wait_for_azure_operation "Kata pool creation" pool_state aks_progress pool_failure_details
az aks update -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --yes --no-wait --output none
wait_for_azure_operation "AKS reconciliation" aks_state aks_progress aks_failure_details

# ── [6/7] Repair federation and permissions for the new cluster identities ──────
lab_step 6/7 "Repair federation and permissions for the new cluster identities"
issuer="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query oidcIssuerProfile.issuerUrl -o tsv)"
kubelet_principal_id="$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query identityProfile.kubeletidentity.objectId -o tsv)"
[[ -n "$issuer" && -n "$kubelet_principal_id" ]] || die "New AKS OIDC/kubelet identity is missing."
echo "Updating Agent federation to the new AKS OIDC issuer..."
az identity federated-credential update \
  -g "$RESOURCE_GROUP" \
  --identity-name "${CLUSTER_NAME}-agent" \
  --name sandbox-agent \
  --issuer "$issuer" \
  --subject "system:serviceaccount:$NAMESPACE:$SERVICE_ACCOUNT" \
  --audiences api://AzureADTokenExchange \
  --output none
echo "Updating snapshot broker federation to the new AKS OIDC issuer..."
az identity federated-credential update \
  -g "$RESOURCE_GROUP" \
  --identity-name "${CLUSTER_NAME}-snapshot-broker" \
  --name pod-snapshot-broker \
  --issuer "$issuer" \
  --subject system:serviceaccount:pod-snapshot-system:pod-snapshot-broker \
  --audiences api://AzureADTokenExchange \
  --output none
(
  cd "$ROOT"
  az deployment group create \
    -g "$RESOURCE_GROUP" \
    -n sandbox-kubelet-rbac \
    --template-file infra/kubelet-rbac.bicep \
    --parameters \
      acrName="$acr_name" \
      storageAccountName="$storage_account" \
      kubeletPrincipalId="$kubelet_principal_id" \
    --no-wait \
    --output none
)
rbac_state() {
  az deployment group show -g "$RESOURCE_GROUP" -n sandbox-kubelet-rbac \
    --query properties.provisioningState -o tsv
}
rbac_progress() {
  az deployment operation group list -g "$RESOURCE_GROUP" -n sandbox-kubelet-rbac \
    --query '[?properties.targetResource.resourceName!=`null`].{Resource:properties.targetResource.resourceName,State:properties.provisioningState}' \
    -o table
  if [[ "$(rbac_state)" == Failed ]]; then
    az deployment group show -g "$RESOURCE_GROUP" -n sandbox-kubelet-rbac \
      --query properties.error -o json
  fi
}
wait_for_azure_operation "Kubelet RBAC deployment" rbac_state rbac_progress
load_outputs
connect

# ── [7/7] Wait for genuine v2 capability and run strict runtime verification ────
lab_step 7/7 "Wait for genuine v2 capability and run strict runtime verification"
started=$SECONDS
deadline=$((SECONDS + TIMEOUT_SECONDS))
v2_unavailable="Kata v2 is still unavailable after $TIMEOUT. The new cluster is retained; inspect regional/backend enablement instead of repeatedly rebuilding."
while true; do
  remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || die "$v2_unavailable"
  request_timeout=30
  if (( remaining < request_timeout )); then
    request_timeout=$remaining
  fi
  handler="$(kubectl get runtimeclass kata-vm-isolation-v2 --ignore-not-found \
    -o jsonpath='{.handler}' --request-timeout="${request_timeout}s")"
  remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || die "$v2_unavailable"
  if (( remaining < request_timeout )); then
    request_timeout=$remaining
  fi
  capable="$(kubectl get nodes \
    -l "agentpool=$NODEPOOL_NAME,kubernetes.azure.com/kata-vm-isolation-v2=true" \
    -o go-template='{{len .items}}' --request-timeout="${request_timeout}s")"
  echo "[$(date '+%H:%M:%S')] Kata v2: handler=${handler:-absent}, nodes=$capable/$KATA_NODE_COUNT (elapsed $((SECONDS - started))s; limit $TIMEOUT)"
  if [[ "$handler" == kata-v2 && "$capable" == "$KATA_NODE_COUNT" ]]; then
    break
  fi
  remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || die "$v2_unavailable"
  delay=30
  if (( remaining < delay )); then
    delay=$remaining
  fi
  sleep "$delay"
done
bash "$ROOT/scripts/02-verify-runtime.sh"
echo "AKS rebuilt and Kata v2 verified. Reinstall cluster extensions with scripts/03-install-extensions.sh."
echo "Existing image and Blob data are retained; deploy new workloads rather than reusing old in-memory session markers."
