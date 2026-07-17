#!/bin/bash
# setup.sh — Module 1: one-step core infrastructure deployment.
#
# Thin wrapper around `az deployment sub create` for main.bicep, so the
# workshop can provision everything with a single `./setup.sh` call instead of
# typing the az deployment command by hand. The result is identical to running
# the Bicep deployment manually (see README Step 2).
#
# Usage:
#   ./setup.sh
#
# Optional overrides (export before running):
#   RESOURCE_GROUP   default: rg-agenthost-workshop
#   LOCATION         default: eastus2
#   DEPLOYMENT_SN    default: random 6-hex suffix (openssl rand -hex 3)
# Any other main.bicep parameter can be overridden by appending
# `key=value` pairs as script arguments, e.g.:
#   ./setup.sh projectName=my-proj modelDeploymentName=gpt-5.4-mini

set -euo pipefail

# Resolve the directory of this script so main.bicep is found from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-agenthost-workshop}"
LOCATION="${LOCATION:-eastus2}"

# Random deployment suffix — feeds main.bicep's deploymentSN param, which
# suffixes globally-unique resource names (matches README's openssl rand -hex 3).
if [[ -z "${DEPLOYMENT_SN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    DEPLOYMENT_SN="$(openssl rand -hex 3)"
  else
    DEPLOYMENT_SN="$(date -u +%H%M%S)"
  fi
fi

DEPLOYMENT_NAME="main-${DEPLOYMENT_SN}"
BICEP_PATH="./main.bicep"

echo "==> Deploying main.bicep (single-step Bicep provisioning)"
echo "    Resource Group  : $RESOURCE_GROUP"
echo "    Location        : $LOCATION"
echo "    Deployment SN   : $DEPLOYMENT_SN"
echo "    Deployment name : $DEPLOYMENT_NAME"
echo "    Bicep path      : $BICEP_PATH"
echo ""

az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$LOCATION" \
  --template-file "$BICEP_PATH" \
  --parameters \
      resourceGroupName="$RESOURCE_GROUP" \
      location="$LOCATION" \
      deploymentSN="$DEPLOYMENT_SN" \
      "$@" \
  --output none

echo ""
echo "==> Deployment '$DEPLOYMENT_NAME' complete. Outputs:"
az deployment sub show \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs \
  --output jsonc

echo ""
echo "Next: proceed to module-02 to deploy the hosted agent with azd."
