#!/usr/bin/env bash
# Delete current agent-pool Claims and their owned resources, preserving the pool.
#
# Usage: bash scripts/05-delete-claims.sh
# Configuration: Exported NAMESPACE (default agent-lab) and TIMEOUT (default 10m).
# Prerequisites: Prepared kubectl context, Python 3 and running Sandbox controllers.
# WARNING: Claimed sessions lose their live in-memory state.

set -euo pipefail

# --- Validate the deletion scope ---
if [[ "$#" -ne 0 ]]; then
  echo "ERROR: Usage: bash scripts/05-delete-claims.sh" >&2
  exit 1
fi

namespace="${NAMESPACE-agent-lab}"
timeout="${TIMEOUT-10m}"

if [[ ! "$namespace" =~ ^[a-z][a-z0-9-]{0,62}$ ||
      "$namespace" == kube-* || "$namespace" == default ]]; then
  echo "ERROR: Set NAMESPACE to a dedicated non-system namespace" >&2
  exit 1
fi

if [[ ! "$timeout" =~ ^[1-9][0-9]*[smh]$ ]]; then
  echo "ERROR: Set TIMEOUT to a positive duration such as 10m" >&2
  exit 1
fi

# --- Select a snapshot of current Claims referencing the lab pool ---
claims_json="$(kubectl -n "$namespace" get sandboxclaims -o json)"
claim_names="$(printf '%s\n' "$claims_json" | python3 -c '
import json
import sys

for claim in json.load(sys.stdin)["items"]:
    if claim["spec"].get("warmPoolRef", {}).get("name") == "agent-pool":
        print(claim["metadata"]["name"])
')"

if [[ -z "$claim_names" ]]; then
  echo "No claims reference agent-pool in $namespace; nothing to delete."
  exit 0
fi

# --- Foreground deletion releases Claim-owned Sandboxes, Pods, Services and routes ---
mapfile -t claims <<< "$claim_names"
echo "Deleting ${#claims[@]} current agent-pool Claims in $namespace..."
kubectl -n "$namespace" delete sandboxclaim "${claims[@]}" \
  --cascade=foreground \
  --ignore-not-found \
  --wait=true \
  --timeout="$timeout"

echo "Current agent-pool Claims and their owned resources have been deleted."
echo "The warm pool, template, unclaimed reserves and shared Gateway are preserved."
