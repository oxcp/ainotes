#!/usr/bin/env bash
# Module 2 deployment helper for the Foundry hosted-agent flow.
# Usage: ./deploy.sh
# Prerequisites: Module 1 infrastructure must be deployed first.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
LOCATION="${LOCATION:-eastus2}"
FOUNDRY_RESOURCE_NAME="${FOUNDRY_RESOURCE_NAME:-foundry-agenthost}"
PROJECT_NAME="${PROJECT_NAME:-maf-agent-basic-resp}"
APIM_NAME="${APIM_NAME:-apim-agenthost}"

echo "==> Deploying Foundry resource and project"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file hostedagent.bicep \
  --parameters \
    location="$LOCATION" \
    foundryResourceName="$FOUNDRY_RESOURCE_NAME" \
    projectName="$PROJECT_NAME" \
    apimName="$APIM_NAME"

echo ""
echo "==> Foundry infrastructure deployment complete"
echo ""
echo "Next steps:"
echo "  1. Initialize the hosted agent from the sample azure.yaml"
echo "  2. Run azd provision"
echo "  3. Run azd ai agent run"
echo "  4. Run azd deploy"
echo "  5. Invoke with azd ai agent invoke \"Hi\""