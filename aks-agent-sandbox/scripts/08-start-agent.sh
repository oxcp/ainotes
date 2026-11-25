#!/usr/bin/env bash
# Start the chat agent separately from the in-memory snapshot test.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── Discover the built image and connect to the dedicated cluster ──────────────
lab_step 1/3 "Discover the built image and connect to the dedicated cluster"
load_outputs
check_image
connect
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── Configure Workload Identity without mounting Blob ─────────────────────────
lab_step 2/3 "Configure Workload Identity without mounting Blob"
render agent-identity.yaml | kubectl apply -f -

# ── Start the Agent with its ACR digest and verify startup ─────────────────────
lab_step 3/3 "Start the Agent with its ACR digest and verify startup"
render reflection-agent.yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready sandbox/reflection-agent \
  --timeout="$TIMEOUT"
kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready pod \
  -l app=reflection-agent \
  --timeout="$TIMEOUT"

echo "Agent ready. Open its portal using:"
echo "kubectl -n $NAMESPACE port-forward service/reflection-agent 8080:8080"
echo "Then visit http://127.0.0.1:8080. Only an actual chat verifies model inference."
