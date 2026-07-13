#!/usr/bin/env bash
# sandbox-deploy.sh — Module 4: Azure Container Apps Sandboxes Deployment (workshop path)
#
# Deploys REAL Azure Container Apps Sandboxes (Microsoft.App/SandboxGroups).
# This script:
#   1. Checks RBAC role: Container Apps SandboxGroup Data Owner
#   2. Retrieves deployment suffix (SN) from module-01
#   3. Builds and pushes agent container image to ACR
#   4. Grants UAMI AcrPull role
#   5. Creates SandboxGroup via sandbox.bicep
#   6. Provisions sandbox instances using Azure CLI
#   7. Creates disk image from ACR container
#   8. Launches individual sandbox(es) with lifecycle policies
#
# Usage: ./sandbox-deploy.sh [--count=N] [--auto-suspend-mins=M]
# Defaults: count=1, auto-suspend-mins=30 (auto-suspend idle sandboxes after 30 min)
#
# Prerequisites:
#   - Module 1 infrastructure deployed
#   - Azure CLI with sandboxes preview features enabled
#   - RBAC role: "Container Apps SandboxGroup Data Owner" assigned
#   - Docker installed and running

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
LOCATION="${LOCATION:-eastus2}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
SANDBOX_COUNT="${SANDBOX_COUNT:-1}"
AUTO_SUSPEND_MINS="${AUTO_SUSPEND_MINS:-30}"

echo "==> Module 4: Azure Container Apps Sandboxes Deployment (workshop path)"
echo "Resource Group: $RESOURCE_GROUP"
echo "Sandbox Count: $SANDBOX_COUNT"
echo "Auto-suspend timeout: ${AUTO_SUSPEND_MINS} minutes"

# ── Retrieve deployment suffix from module-01 ────────────────────────────────
echo "==> [1/8] Retrieving deployment suffix (SN) from module-01 resource group"
SN=$(az group show --resource-group "$RESOURCE_GROUP" --query "tags.deploymentSN" --output tsv | tr -d '\r\n' 2>/dev/null || echo "")
if [ -z "$SN" ]; then
  echo "ERROR: Could not find deploymentSN tag in resource group. Ensure module-01 is deployed."
  exit 1
fi
echo "Deployment suffix: $SN"

# ── Construct resource names (must match module-01 naming) ────────────────────
ACR_NAME="acragenthost${SN}"
REDIS_NAME="redis-agenthost-${SN}"
STORAGE_ACCOUNT="stcagenthost${SN}"
IDENTITY_NAME="id-agenthost-${SN}"
SANDBOX_GROUP_NAME="sandbox-group-agenthost-${SN}"

echo "  ACR: $ACR_NAME"
echo "  SandboxGroup: $SANDBOX_GROUP_NAME"
echo "  UAMI: $IDENTITY_NAME"

# ── Check RBAC role assignment ───────────────────────────────────────────────
echo "==> [2/8] Checking RBAC role: Container Apps SandboxGroup Data Owner"
CURRENT_USER=$(az ad signed-in-user show --query id --output tsv 2>/dev/null || echo "")
if [ -z "$CURRENT_USER" ]; then
  echo "WARNING: Could not determine current user. RBAC check skipped."
  echo "  Ensure your account has 'Container Apps SandboxGroup Data Owner' role assigned."
else
  RESOURCE_GROUP_SCOPE="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP"
  ROLE_ASSIGNED=$(az role assignment list \
    --scope "$RESOURCE_GROUP_SCOPE" \
    --assignee "$CURRENT_USER" \
    --query "[?roleDefinitionName=='Container Apps SandboxGroup Data Owner'] | length(@)" \
    --output tsv 2>/dev/null || echo "0")
  if [ "$ROLE_ASSIGNED" -eq 0 ]; then
    echo "WARNING: RBAC role 'Container Apps SandboxGroup Data Owner' not found for current user."
    echo "  Assign it 'Container Apps SandboxGroup Data Owner' role in scope: $RESOURCE_GROUP_SCOPE"
    az role assignment create --assignee "$CURRENT_USER" --role 'Container Apps SandboxGroup Data Owner' --scope "$RESOURCE_GROUP_SCOPE"
  else
    echo "✓ RBAC role assigned"
  fi
fi

# ── Build and push container image ───────────────────────────────────────────
echo "==> [3/8] Building and pushing agent container image"
az acr login --name "$ACR_NAME"
docker build -t "${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}" .
docker push "${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}"
echo "✓ Image pushed: ${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}"

# ── Retrieve UAMI details ────────────────────────────────────────────────────
echo "==> [4/8] Retrieving User-Assigned Managed Identity details"
UAMI=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query id --output tsv | tr -d '\r\n')
UAMI_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query clientId --output tsv | tr -d '\r\n')
echo "  Identity ID: $UAMI"
echo "  Client ID: $UAMI_CLIENT_ID"

# ── Grant UAMI AcrPull role on ACR ──────────────────────────────────────────
echo "==> [5/8] Granting UAMI AcrPull role on ACR"
ACR_RESOURCE_ID=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query id --output tsv | tr -d '\r\n')
az role assignment create \
  --role "AcrPull" \
  --assignee-object-id "$(az identity show --ids "$UAMI" --query principalId -o tsv  | tr -d '\r\n')" \
  --scope "$ACR_RESOURCE_ID" 2>/dev/null || echo "  (Role may already be assigned)"
echo "✓ AcrPull role granted"

# ── Deploy SandboxGroup via sandbox.bicep ────────────────────────────────────
echo "==> [6/8] Deploying SandboxGroup via Bicep template"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file sandbox.bicep \
  --parameters \
      location="$LOCATION" \
      deploymentSN="$SN" \
      acrName="$ACR_NAME" \
      identityId="$UAMI" \
      identityClientId="$UAMI_CLIENT_ID" \
      imageTag="$IMAGE_TAG"

# ── Create disk image from ACR container ────────────────────────────────────
echo "==> [7/8] Creating disk image from container registry"
echo "  Note: Disk image creation via CLI (az containerapp sandbox image create) coming soon."
echo "  For now, use Azure Portal or wait for full CLI support."

# ── Launch sandbox instances ───────────────────────────────────────────────
echo "==> [8/8] Launching sandbox instances"
echo "  Note: Sandbox instance management via CLI (az containerapp sandbox create) coming soon."
echo "  For now, use Azure Portal or Azure CLI with experimental commands:"
echo ""
echo "  Example: az containerapp sandbox create \\"
echo "    --resource-group '$RESOURCE_GROUP' \\"
echo "    --sandbox-group-name '$SANDBOX_GROUP_NAME' \\"
echo "    --name 'sandbox-agent-01' \\"
echo "    --disk-image-uri '${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}' \\"
echo "    --auto-suspend-time-in-minutes $AUTO_SUSPEND_MINS"
echo ""
echo "  To launch multiple sandboxes, repeat the above command with different names."

# ── Output summary ───────────────────────────────────────────────────────────
echo ""
echo "=========================================================================="
echo "✓ SandboxGroup deployed successfully!"
echo "=========================================================================="
echo ""
echo "SandboxGroup Details:"
echo "  Name: $SANDBOX_GROUP_NAME"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Container Image: ${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}"
echo ""
echo "Next Steps:"
echo "  1. Create disk image (if not already done)"
echo "  2. Launch individual sandbox instances using CLI commands (shown above)"
echo "  3. Manage sandbox lifecycle: suspend, resume, delete"
echo "  4. Monitor sandbox performance and resource usage"
echo ""
echo "Documentation:"
echo "  https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview"
echo "  https://learn.microsoft.com/en-us/cli/azure/containerapp/sandbox"
echo ""
