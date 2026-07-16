#!/usr/bin/env bash
# lifecycle-hook.sh — preStop hook for the agent-sandbox Sandbox pod.
# Runs on SIGTERM (hibernate / delete / rolling update). Flushes the agent's
# hot state from Azure Managed Redis to Azure Blob Storage so it can be
# restored on the next resume.
#
# Wired via agent-sandbox.yaml:
#   lifecycle: { preStop: { exec: { command: ["/app/lifecycle-hook.sh"] } } }
#
# Environment (injected by agent-sandbox.yaml):
#   AGENT_ID                — unique agent identifier
#   AGENT_REDIS_CONNECTION  — "<host>:10000,password=<key>,ssl=True,abortConnect=False"
#   AGENT_STORAGE_ACCOUNT   — Azure Blob Storage account name
#   AGENT_BLOB_CONTAINER    — Blob container (e.g. "agent-state")
#   AZURE_CLIENT_ID         — UAMI client ID (Workload Identity, injected automatically)

set -euo pipefail

AGENT_ID="${AGENT_ID:-unknown}"
STORAGE_ACCOUNT="${AGENT_STORAGE_ACCOUNT:-}"
CONTAINER="${AGENT_BLOB_CONTAINER:-agent-state}"
STATE_FILE="/tmp/agent-state-${AGENT_ID}.json"
BLOB_NAME="agents/${AGENT_ID}/state.json"

echo "[lifecycle-hook] preStop for agent: $AGENT_ID — flushing Redis -> Blob"

# Authenticate with Workload Identity (federated UAMI; no client secret).
if ! az login --identity --username "${AZURE_CLIENT_ID:-}" --allow-no-subscriptions --output none 2>&1; then
  echo "[lifecycle-hook] WARNING: UAMI login failed; Blob upload may fail."
fi

# Export the agent's state key from Redis (same key the app uses: agent:state:<id>).
python3 - <<'PY'
import os, ssl
try:
    import redis
except ImportError:
    print("[lifecycle-hook] redis module missing; skipping export"); raise SystemExit(0)

conn = os.environ.get("AGENT_REDIS_CONNECTION", "")
agent_id = os.environ.get("AGENT_ID", "unknown")
state_file = f"/tmp/agent-state-{agent_id}.json"

# Parse "<host>:<port>,password=..,ssl=True"
parts = conn.split(",")
host, port = (parts[0].split(":") + ["10000"])[:2]
opts = {}
for p in parts[1:]:
    if "=" in p:
        k, v = p.split("=", 1)
        opts[k.strip()] = v.strip()
use_ssl = str(opts.get("ssl", "False")).lower() == "true"

try:
    r = redis.Redis(host=host, port=int(port), password=opts.get("password"),
                    ssl=use_ssl, decode_responses=True)
    state = r.get(f"agent:state:{agent_id}")
    if state:
        with open(state_file, "w") as f:
            f.write(state)
        print("[lifecycle-hook] State exported from Redis.")
    else:
        print("[lifecycle-hook] No state found in Redis; nothing to flush.")
except Exception as e:
    print(f"[lifecycle-hook] Redis export failed: {e}")
PY

# Upload the snapshot to Blob Storage.
if [[ -f "$STATE_FILE" && -n "$STORAGE_ACCOUNT" ]]; then
  az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$BLOB_NAME" \
    --file "$STATE_FILE" \
    --overwrite \
    --auth-mode login \
    --output none
  echo "[lifecycle-hook] State flushed to Blob: ${STORAGE_ACCOUNT}/${CONTAINER}/${BLOB_NAME}"
  rm -f "$STATE_FILE"
else
  echo "[lifecycle-hook] No state file or storage account; skipping Blob write."
fi

echo "[lifecycle-hook] Done. Container will now terminate."
