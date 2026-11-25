#!/usr/bin/env bash
# 07-restore.sh — Restore a named Sandbox through the shared portal restore flow
#
# Usage: bash scripts/07-restore.sh <sandbox-name>
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: Matching snapshot mapping, existing Sandbox, RBAC/impersonation rights.

set -euo pipefail

if [[ $# -ne 1 ||
      ! "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Usage: bash scripts/07-restore.sh <sandbox-name>" >&2
  exit 2
fi

source_sandbox="$1"
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/2] Connect and pin the restore context ──────────────────────────────────
lab_step 1/2 "Connect and select the restore context"
connect
context="$(kubectl config current-context)"
[[ -n "$context" ]] || die "Select a kubectl context before restoring."

# ── [2/2] Reuse snapshot validation, authorization and same-name recreation ─────
lab_step 2/2 "Restore Sandbox $source_sandbox from its mapped snapshot"
python3 "$ROOT/sandbox_portal.py" \
  --namespace "$NAMESPACE" \
  --context "$context" \
  --restore "$source_sandbox"
