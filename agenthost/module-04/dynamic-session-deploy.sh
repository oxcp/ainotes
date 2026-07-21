#!/usr/bin/env bash
# dynamic-session-deploy.sh — Module 4: ACA Dynamic Sessions Deployment (optional learning track)
#
# Deploys Azure Container Apps Dynamic Sessions (Session Pool) using custom container.
# This script:
#   1. Retrieves deployment suffix (SN) from module-01
#   2. Reuses the Module-03 agent container image already in ACR
#   3. Creates (or reuses) ACA environment for session pools
#   4. Creates/updates a custom-container session pool
#   5. Outputs pool management endpoint for invocation
#
# Usage:
#   ./dynamic-session-deploy.sh
#
# Optional env vars:
#   RESOURCE_GROUP=rg-agenthost-workshop
#   LOCATION=eastus2
#   IMAGE_TAG=latest
#   SESSION_POOL_NAME=sessionpool-agenthost-<SN>
#   SESSION_ENV_NAME=aca-session-env-agenthost-<SN>
#   TARGET_PORT=8088
#   MAX_SESSIONS=50
#   READY_SESSIONS=3
#   COOLDOWN_PERIOD=600
#   NETWORK_STATUS=EgressDisabled  # or EgressEnabled

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
LOCATION="${LOCATION:-eastus2}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
TARGET_PORT="${TARGET_PORT:-8088}"
MAX_SESSIONS="${MAX_SESSIONS:-50}"
READY_SESSIONS="${READY_SESSIONS:-3}"
COOLDOWN_PERIOD="${COOLDOWN_PERIOD:-600}"
NETWORK_STATUS="${NETWORK_STATUS:-EgressDisabled}"

# Ensure preview extension support is present.
az extension add --name containerapp --upgrade --allow-preview true -y >/dev/null

echo "==> Module 4: ACA Dynamic Sessions Deployment (optional learning track)"
echo "Resource Group: $RESOURCE_GROUP"

# 1) Retrieve deployment SN.
echo "==> [1/5] Retrieving deployment suffix (SN)"
SN=$(az group show --resource-group "$RESOURCE_GROUP" --query "tags.deploymentSN" --output tsv 2>/dev/null || echo "")
if [ -z "$SN" ]; then
  echo "ERROR: Could not find deploymentSN tag in resource group. Ensure module-01 is deployed."
  exit 1
fi

echo "Deployment suffix: $SN"
ACR_NAME="acragenthost${SN}"
SESSION_POOL_NAME="${SESSION_POOL_NAME:-sessionpool-agenthost-${SN}}"
SESSION_ENV_NAME="${SESSION_ENV_NAME:-aca-session-env-agenthost-${SN}}"
IMAGE="${ACR_NAME}.azurecr.io/agent-host:${IMAGE_TAG}"

echo "  ACR: $ACR_NAME"
echo "  Session Env: $SESSION_ENV_NAME"
echo "  Session Pool: $SESSION_POOL_NAME"

# 2) Reuse Module-03 image.
echo "==> [2/5] Reusing Module-03 agent image in ACR"
echo "  Image: $IMAGE"

# 3) Create or reuse ACA environment.
echo "==> [3/5] Ensuring ACA environment exists"
if ! az containerapp env show --name "$SESSION_ENV_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az containerapp env create \
    --name "$SESSION_ENV_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" >/dev/null
  echo "  Created environment: $SESSION_ENV_NAME"
else
  echo "  Reusing environment: $SESSION_ENV_NAME"
fi

# 4) Create/update session pool.
echo "==> [4/5] Creating/updating dynamic session pool"
if az containerapp sessionpool show --name "$SESSION_POOL_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az containerapp sessionpool update \
    --name "$SESSION_POOL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --image "$IMAGE" \
    --max-sessions "$MAX_SESSIONS" \
    --ready-sessions "$READY_SESSIONS" \
    --cooldown-period "$COOLDOWN_PERIOD" \
    --network-status "$NETWORK_STATUS" >/dev/null
  echo "  Updated session pool: $SESSION_POOL_NAME"
else
  az containerapp sessionpool create \
    --name "$SESSION_POOL_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --environment "$SESSION_ENV_NAME" \
    --container-type CustomContainer \
    --image "$IMAGE" \
    --target-port "$TARGET_PORT" \
    --cpu 0.5 \
    --memory 1.0Gi \
    --cooldown-period "$COOLDOWN_PERIOD" \
    --max-sessions "$MAX_SESSIONS" \
    --ready-sessions "$READY_SESSIONS" \
    --network-status "$NETWORK_STATUS" >/dev/null
  echo "  Created session pool: $SESSION_POOL_NAME"
fi

# 5) Print endpoint.
echo "==> [5/5] Retrieving pool management endpoint"
POOL_ENDPOINT=$(az containerapp sessionpool show \
  --name "$SESSION_POOL_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.poolManagementEndpoint" \
  --output tsv)

echo ""
echo "=========================================================================="
echo "✓ Dynamic Session Pool ready"
echo "=========================================================================="
echo "Pool Name:         $SESSION_POOL_NAME"
echo "Environment Name:  $SESSION_ENV_NAME"
echo "Image:             $IMAGE"
echo "Management URL:    $POOL_ENDPOINT"
echo ""
echo "Example invoke (custom container endpoint):"
echo "  curl -X POST \"${POOL_ENDPOINT}/health?identifier=test-session\" \\"
echo "    -H \"Authorization: Bearer \\$(az account get-access-token --resource https://dynamicsessions.io --query accessToken -o tsv)\""
echo ""
echo "Docs: https://learn.microsoft.com/en-us/azure/container-apps/session-pool"
