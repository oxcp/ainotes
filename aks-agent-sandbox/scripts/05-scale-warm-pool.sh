#!/usr/bin/env bash
# Set the reserve capacity of an existing warm pool without changing its template.
#
# Usage: bash scripts/05-scale-warm-pool.sh <capacity>
# Configuration: NAMESPACE environment variable (defaults to agent-lab).
# Prerequisites: Existing agent-pool and a prepared kubectl context.

set -euo pipefail

# --- Validate the requested target capacity ---
if [[ "$#" -ne 1 || ! "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "ERROR: Usage: bash scripts/05-scale-warm-pool.sh <nonnegative-capacity>" >&2
  exit 1
fi
if [[ "${#1}" -gt 10 ]] || (( $1 > 2147483647 )); then
  echo "ERROR: Capacity must not exceed 2147483647 (Kubernetes int32 limit)." >&2
  exit 1
fi

namespace="${NAMESPACE-agent-lab}"
if [[ ! "$namespace" =~ ^[a-z][a-z0-9-]{0,62}$ ||
      "$namespace" == kube-* || "$namespace" == default ]]; then
  echo "ERROR: Set NAMESPACE to a dedicated non-system namespace" >&2
  exit 1
fi

# --- Update only the reserve target; the controller reconciles asynchronously ---
kubectl -n "$namespace" patch sandboxwarmpool agent-pool \
  --type=merge \
  --patch "{\"spec\":{\"replicas\":$1}}"

printf 'Target warm reserve capacity: %s. Readiness converges asynchronously.\n' "$1"
