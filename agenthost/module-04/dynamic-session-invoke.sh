#!/usr/bin/env bash
# dynamic-session-invoke.sh — Minimal invocation example for the optional Dynamic Sessions learning track
#
# Calls a custom-container Dynamic Session endpoint using session identifier routing.
# Default target endpoint: /health
#
# Usage:
#   ./dynamic-session-invoke.sh
#   ./dynamic-session-invoke.sh <identifier>
#   ENDPOINT_PATH=/api/projects/demo/openai/v1/responses METHOD=POST BODY='{"messages":[{"role":"user","content":"hello"}]}' ./dynamic-session-invoke.sh my-session-1
#
# Optional env vars:
#   RESOURCE_GROUP=rg-agenthost-workshop
#   SESSION_POOL_NAME=sessionpool-agenthost-<SN>
#   ENDPOINT_PATH=/health
#   METHOD=POST
#   BODY='{}'
#   TOKEN_RESOURCE=https://dynamicsessions.io

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
ENDPOINT_PATH="${ENDPOINT_PATH:-/health}"
METHOD="${METHOD:-POST}"
BODY="${BODY:-}"
TOKEN_RESOURCE="${TOKEN_RESOURCE:-https://dynamicsessions.io}"
IDENTIFIER="${1:-test-session}"

# Get deployment suffix (SN) to derive default session pool name.
SN=$(az group show --resource-group "$RESOURCE_GROUP" --query "tags.deploymentSN" --output tsv 2>/dev/null || echo "")
if [ -z "$SN" ]; then
  echo "ERROR: Could not find deploymentSN tag in $RESOURCE_GROUP"
  exit 1
fi

SESSION_POOL_NAME="${SESSION_POOL_NAME:-sessionpool-agenthost-${SN}}"

POOL_ENDPOINT=$(az containerapp sessionpool show \
  --name "$SESSION_POOL_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.poolManagementEndpoint" \
  --output tsv)

if [ -z "$POOL_ENDPOINT" ]; then
  echo "ERROR: Could not resolve poolManagementEndpoint for $SESSION_POOL_NAME"
  exit 1
fi

ACCESS_TOKEN=$(az account get-access-token --resource "$TOKEN_RESOURCE" --query accessToken --output tsv)
if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: Failed to acquire access token for resource $TOKEN_RESOURCE"
  exit 1
fi

if [ "${ENDPOINT_PATH:0:1}" != "/" ]; then
  ENDPOINT_PATH="/${ENDPOINT_PATH}"
fi

URL="${POOL_ENDPOINT}${ENDPOINT_PATH}?identifier=${IDENTIFIER}"

echo "Invoking session pool endpoint"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Session Pool:   $SESSION_POOL_NAME"
echo "  Identifier:     $IDENTIFIER"
echo "  URL:            $URL"

if [ -n "$BODY" ]; then
  curl -sS -X "$METHOD" "$URL" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$BODY"
else
  curl -sS -X "$METHOD" "$URL" \
    -H "Authorization: Bearer $ACCESS_TOKEN"
fi

echo ""
