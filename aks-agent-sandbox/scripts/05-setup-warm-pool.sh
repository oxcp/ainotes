#!/usr/bin/env bash
# 05-setup-warm-pool.sh — Create a warm pool without claiming a session
#
# Usage: bash scripts/05-setup-warm-pool.sh [reserve-count] (minimum/default: 50)
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: Agent Sandbox extension ready and a digest-pinned workload image.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/2] Validate the image, cluster access and reserve size ────────────────────
lab_step 1/2 "Validate the image, cluster access and reserve size"
[[ "$#" -le 1 ]] || die "Usage: bash scripts/05-setup-warm-pool.sh [reserve-count] (minimum/default: 50)."
reserve_count="${1-50}"
[[ "$reserve_count" =~ ^[1-9][0-9]*$ ]] || die "Reserve count must be a positive integer of at least 50."
if [[ "${#reserve_count}" -le 2 ]] && (( reserve_count < 50 )); then
  die "Reserve count must be at least 50; received $reserve_count. Pass 50 or higher as the argument."
fi
if [[ "$#" -eq 0 ]]; then
  echo "No reserve count supplied; using the minimum default of 50."
fi
load_outputs
check_image
connect

# ── [2/2] Create the template and wait for the warm reserve ─────────────────────
lab_step 2/2 "Create the template and wait for the warm reserve"
render agent-identity.yaml | kubectl apply -f -
# Reuse precisely the same application, readiness probe and sizing as the session.
render session.yaml |
  python3 "$ROOT/scripts/make-warm-pool.py" "$reserve_count" \
    --apply "$ROOT/.lab/warm-pool.yaml" \
    --timeout "$TIMEOUT"

echo "Warm pool agent-pool is ready with $reserve_count reserved sessions; no claim was created."
echo "Run bash scripts/05-claim-sandbox.sh 1 separately to claim a session."
