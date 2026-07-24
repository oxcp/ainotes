#!/usr/bin/env bash
set -euo pipefail
source .env
: "${AZURE_LOCATION:?Set AZURE_LOCATION in .env}"
echo "Review compute usage/quota for ${AZURE_LOCATION}."
az vm list-usage --location "$AZURE_LOCATION" --output table
