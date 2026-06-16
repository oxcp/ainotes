#!/usr/bin/env bash
# lifecycle-hook.sh — Module 3: Scale-to-zero state flush hook
# Executed inside the container on SIGTERM (scale-to-zero or rolling update).
# Flushes the agent's hot state from Azure Managed Redis to Azure Blob Storage
# so it can be restored on the next request.
#
# This script is invoked by the container entrypoint/signal handler:
#   trap '/app/lifecycle-hook.sh' SIGTERM
#
# Environment variables (set by ACA / Bicep deployment):
#   AGENT_ID                — unique agent identifier
#   OPENCLAW_REDIS_CONNECTION — Redis connection string
#   OPENCLAW_STORAGE_ACCOUNT  — Azure Blob Storage account name
#   OPENCLAW_BLOB_CONTAINER   — Blob container name (e.g. "openclaw-state")
#   AZURE_CLIENT_ID           — UAMI client ID for az login

set -euo pipefail

AGENT_ID="${AGENT_ID:-unknown}"
STORAGE_ACCOUNT="${OPENCLAW_STORAGE_ACCOUNT:-stcopenclaw}"
CONTAINER="${OPENCLAW_BLOB_CONTAINER:-openclaw-state}"
STATE_FILE="/tmp/openclaw-state-${AGENT_ID}.json"
BLOB_NAME="agents/${AGENT_ID}/state.json"

echo "[lifecycle-hook] Scale-to-zero triggered for agent: $AGENT_ID"
echo "[lifecycle-hook] Flushing state from Redis to Blob Storage..."

# Authenticate using UAMI (workload identity — no client secret required)
if ! az login --identity --username "${AZURE_CLIENT_ID:-}" --allow-no-subscriptions --output none 2>&1; then
  echo "[lifecycle-hook] WARNING: UAMI authentication failed. Blob upload may fail."
fi

# Export agent state from Redis to a local JSON file via the OpenClaw CLI
# The OpenClaw process must support: openclaw state export --agent-id <id> --output <file>
if command -v openclaw &>/dev/null; then
  openclaw state export \
    --agent-id "$AGENT_ID" \
    --output "$STATE_FILE" \
    --redis-connection "${OPENCLAW_REDIS_CONNECTION:-}"
else
  echo "[lifecycle-hook] WARNING: openclaw CLI not found; attempting fallback Python export"
  python3 -c "
import os, json, redis, sys
conn = os.environ.get('OPENCLAW_REDIS_CONNECTION', '')
host, rest = conn.split(':6380,', 1) if ':6380,' in conn else (conn, '')
r = redis.Redis(host=host, port=6380, ssl=True, decode_responses=True)
key = f'openclaw:state:{os.environ[\"AGENT_ID\"]}'
state = r.get(key)
if state:
    with open('${STATE_FILE}', 'w') as f:
        f.write(state)
    print('[lifecycle-hook] State exported from Redis.')
else:
    print('[lifecycle-hook] No state found in Redis for this agent.')
    sys.exit(0)
"
fi

# Upload the state snapshot to Azure Blob Storage
if [[ -f "$STATE_FILE" ]]; then
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
  echo "[lifecycle-hook] No state file to upload; skipping Blob write."
fi

echo "[lifecycle-hook] Done. Container will now terminate."
