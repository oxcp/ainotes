#!/usr/bin/env bash
# 04-start-session.sh — Start a cold Sandbox session and record a synthetic task
#
# Usage: bash scripts/04-start-session.sh
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: both extensions ready and a digest-pinned workload image.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/4] Validate the image and load cluster/storage access ────────────────────
lab_step 1/4 "Validate the image and load cluster/storage access"
load_outputs
check_image
connect

# ── [2/4] Configure Workload Identity and wait for the snapshot policy ─────────
lab_step 2/4 "Create the namespace, configure Workload Identity and wait for the snapshot policy"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
render agent-identity.yaml | kubectl apply -f -
render snapshot-policy.yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready podsnapshotpolicy/session-policy \
  --timeout="$TIMEOUT"

# ── [3/4] Install the Gateway, then create the session and its routes ──────────
lab_step 3/4 "Install the Gateway, create the session and wait for application readiness"
render gateway.yaml | kubectl apply -f -
echo "Creating the Agent, ClusterIP Service and HTTPRoute; the portal has no user authentication."
session_started="$(python3 -c 'import time; print(time.monotonic())')"
render session.yaml | kubectl apply -f -
session_submitted="$(python3 -c 'import time; print(time.monotonic())')"
wait_session
session_ready="$(python3 -c 'import time; print(time.monotonic())')"

echo "Session timing (submission includes Sandbox, Service and HTTPRoute; preparation and /work excluded):"
python3 - "$ROOT/scripts" "$session_started" "$session_submitted" "$session_ready" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from sandbox_timing import timing_table

started, submitted, completed = (float(value) for value in sys.argv[2:])
print(timing_table(1, submitted - started, completed - started))
PY

# ── [4/4] Execute a synthetic task and save the in-memory state ─────────────────
lab_step 4/4 "Execute a synthetic task and save the in-memory state"
pod="$(session_pod)"
request "$pod" /work | tee "$ROOT/.lab/before.json"
kubectl -n "$NAMESPACE" get pods -l app=agent-session -o wide
kubectl -n "$NAMESPACE" get service agent-session -o wide
kubectl -n "$NAMESPACE" get gateway sandbox-gateway -o wide

echo "The session ID and completed task are in process memory, not a file or persistent volume."
echo "Once sandbox-gateway has an ADDRESS, open http://<GATEWAY-ADDRESS>/agent-session/ in your browser."
echo "Watch allocation with: kubectl -n $NAMESPACE get gateway sandbox-gateway --watch"
