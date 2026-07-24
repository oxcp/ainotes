#!/usr/bin/env bash
set -euo pipefail
source .env
az group delete -n "$AZURE_RESOURCE_GROUP" --yes --no-wait
echo '[OK] Azure resource-group deletion submitted.'
echo '[INFO] Remove Anyscale jobs/services created by the labs using your approved Anyscale on Azure process.'
