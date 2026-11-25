#!/usr/bin/env bash
# Claim in Ready-reserve-sized rounds, then create Services and Gateway routes.
#
# Usage: bash scripts/05-claim-sandbox.sh <count> [--route]
# Configuration: NAMESPACE environment variable (defaults to agent-lab).
# Prerequisites: Existing agent-pool, shared Gateway and a prepared kubectl context.
# Waiting has no script timeout; Ctrl+C stops without deleting created resources.

set -euo pipefail

route_args=()
if [[ "${1:-}" == --route ]]; then
  route_args=(--route)
  shift
fi
count="${1:-}"
if [[ "$#" -gt 0 ]]; then
  shift
fi
if [[ "${1:-}" == --route && "${#route_args[@]}" -eq 0 ]]; then
  route_args=(--route)
  shift
fi
if [[ "$#" -ne 0 || ! "$count" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: Usage: bash scripts/05-claim-sandbox.sh <positive-count> [--route]" >&2
  exit 1
fi

# --- Reuse the prepared environment without reading configuration files ---
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export NAMESPACE="${NAMESPACE-agent-lab}"

if [[ ! "${NAMESPACE:-}" =~ ^[a-z][a-z0-9-]{0,62}$ ||
      "$NAMESPACE" == kube-* || "$NAMESPACE" == default ]]; then
  echo "ERROR: Set NAMESPACE to a dedicated non-system namespace" >&2
  exit 1
fi

# --- Submit claims and measure submission-to-readiness time ---
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$ROOT/scripts/claim-warm-pool.py" "$count" \
  "$ROOT/manifests/claim.yaml" "${route_args[@]}"
