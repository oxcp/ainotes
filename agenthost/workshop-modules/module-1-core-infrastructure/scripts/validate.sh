#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BICEP_FILE="${MODULE_DIR}/infra/main.bicep"
ARM_FILE="${MODULE_DIR}/infra/main.json"

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: Azure CLI (az) is required for Bicep validation."
  exit 1
fi

echo "[1/3] Building Bicep template (syntax + basic semantic checks)..."
az bicep build --file "${BICEP_FILE}" --outfile "${ARM_FILE}"

echo "[2/3] Linting Bicep template..."
az bicep lint --file "${BICEP_FILE}"

echo "[3/3] Optional ARM validation (disabled by default; no deployment)"
if [[ "${RUN_AZ_VALIDATE:-false}" == "true" ]]; then
  : "${AZ_RESOURCE_GROUP:?Set AZ_RESOURCE_GROUP to enable az deployment group validate}"
  : "${AZ_LOCATION:?Set AZ_LOCATION to enable az deployment group validate}"
  : "${AZ_NAME_PREFIX:?Set AZ_NAME_PREFIX to enable az deployment group validate}"

  az deployment group validate \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --template-file "${BICEP_FILE}" \
    --parameters location="${AZ_LOCATION}" namePrefix="${AZ_NAME_PREFIX}"

  az deployment group what-if \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --template-file "${BICEP_FILE}" \
    --parameters location="${AZ_LOCATION}" namePrefix="${AZ_NAME_PREFIX}"
else
  echo "Skipped az deployment group validate/what-if."
  echo "Set RUN_AZ_VALIDATE=true and provide AZ_RESOURCE_GROUP, AZ_LOCATION, AZ_NAME_PREFIX to run dry-run checks."
fi

echo "Validation completed successfully (no deployment executed)."
