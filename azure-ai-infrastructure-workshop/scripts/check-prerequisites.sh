#!/usr/bin/env bash
set -euo pipefail
for cmd in az kubectl helm git python3; do
  command -v "$cmd" >/dev/null || { echo "[ERROR] Missing: $cmd"; exit 1; }
done
az account show --output table
echo '[OK] Local prerequisites found.'
