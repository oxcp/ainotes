#!/usr/bin/env bash
# lifecycle-hook.sh — preStop hook for the agent-sandbox Sandbox pod.
# Runs on SIGTERM (hibernate / delete / rolling update).
#
# State model: the agent persists conversation state as <AGENT_ID>.json on the
# mounted Blob volume after every chat turn. There is no hot cache to flush at
# shutdown, so this hook only verifies the expected state path and logs.
#
# Wired via agent-sandbox.yaml:
#   lifecycle: { preStop: { exec: { command: ["/app/lifecycle-hook.sh"] } } }
#
# Environment (injected by agent-sandbox.yaml):
#   AGENT_ID          — unique agent identifier
#   STATE_MOUNT_PATH  — mounted Blob volume path

set -euo pipefail

AGENT_ID="${AGENT_ID:-unknown}"
STATE_MOUNT_PATH="${STATE_MOUNT_PATH:-/app/app/data}"
STATE_FILE="${STATE_MOUNT_PATH}/${AGENT_ID}.json"

echo "[lifecycle-hook] preStop for agent: $AGENT_ID"
echo "[lifecycle-hook] State is persisted to the mounted volume on every change; nothing to flush."
if [[ -f "$STATE_FILE" ]]; then
  echo "[lifecycle-hook] Latest state is available at $STATE_FILE"
else
  echo "[lifecycle-hook] No state file exists yet at $STATE_FILE"
fi
echo "[lifecycle-hook] Done. Container will now terminate."
