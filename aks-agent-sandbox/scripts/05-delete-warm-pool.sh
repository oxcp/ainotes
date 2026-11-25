#!/usr/bin/env bash
# Delete agent-pool, its claims and agent-template while preserving other workloads.
#
# Usage: bash scripts/05-delete-warm-pool.sh
# Configuration: Exported NAMESPACE (default agent-lab) and TIMEOUT (default 10m).
# Prerequisites: Prepared kubectl context, Python 3 and running Sandbox controllers.
# WARNING: Claimed sessions are destroyed, including their live in-memory state.

set -euo pipefail

# --- Validate the deletion scope ---
[[ "$#" -eq 0 ]] || {
  echo "ERROR: Usage: bash scripts/05-delete-warm-pool.sh" >&2
  exit 1
}
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

# --- Stop replenishment and remove the owned reserve ---
echo "Deleting warm pool agent-pool in $namespace..."
kubectl -n "$namespace" delete sandboxwarmpool agent-pool \
  --cascade=foreground \
  --ignore-not-found \
  --wait=true \
  --timeout="$timeout"

# --- Release only claims that reference this pool ---
claims_json="$(kubectl -n "$namespace" get sandboxclaims -o json)"
claim_names="$(printf '%s\n' "$claims_json" | python3 -c '
import json
import sys

for claim in json.load(sys.stdin)["items"]:
    if claim["spec"].get("warmPoolRef", {}).get("name") == "agent-pool":
        print(claim["metadata"]["name"])
')"
if [[ -n "$claim_names" ]]; then
  mapfile -t claims <<< "$claim_names"
  kubectl -n "$namespace" delete sandboxclaim "${claims[@]}" \
    --cascade=foreground \
    --ignore-not-found \
    --wait=true \
    --timeout="$timeout"
else
  echo "No claims reference agent-pool."
fi

# --- Remove the template after its consumers have been released ---
kubectl -n "$namespace" delete sandboxtemplate agent-template \
  --cascade=foreground \
  --ignore-not-found \
  --wait=true \
  --timeout="$timeout"

echo "Warm pool agent-pool, its claims and agent-template have been deleted."
