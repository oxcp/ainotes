#!/usr/bin/env bash
# Delete agent-session with foreground cascading to its Pods, then its Service and HTTPRoute.
#
# Usage: bash scripts/04-delete-session.sh
# Configuration: Exported NAMESPACE (default agent-lab) and TIMEOUT (default 10m).
# Prerequisites: Prepared kubectl context and running Sandbox controllers.
# WARNING: The session's live in-memory state is lost.

set -euo pipefail

# --- Validate the deletion scope ---
[[ "$#" -eq 0 ]] || {
  echo "ERROR: Usage: bash scripts/04-delete-session.sh" >&2
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

# --- Delete the Sandbox before cleaning up remaining session resources ---
echo "Deleting standalone session agent-session in $namespace..."
kubectl -n "$namespace" delete sandbox agent-session \
  --cascade=foreground \
  --ignore-not-found \
  --wait=true \
  --timeout="$timeout"

# --- Remove the Service and HTTPRoute from session.yaml ---
kubectl -n "$namespace" delete service agent-session \
  --ignore-not-found \
  --wait=true \
  --timeout="$timeout"

kubectl -n "$namespace" delete httproute agent-session \
  --ignore-not-found \
  --wait=true \
  --timeout="$timeout"

echo "Standalone session agent-session, its Service and HTTPRoute have been deleted."
