#!/usr/bin/env bash
# lifecycle-hook.sh — preStop hook for the agent-sandbox Sandbox pod.
# Runs on SIGTERM (hibernate / delete / rolling update).
#
# State model: history stays in memory by default. With persistence enabled and
# a mounted volume, each turn attempts to save <AGENT_ID>.json. This hook only
# reports the configured mode and saved-file presence; it does not flush history.
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
if [[ "${CHAT_PERSISTENCE_ENABLED:-false}" != true ]]; then
  echo "[lifecycle-hook] Persistence disabled; in-memory history will be lost on shutdown."
  exit 0
fi
echo "[lifecycle-hook] Persistence enabled; check Agent logs for any save failures. Nothing to flush."
if [[ -f "$STATE_FILE" ]]; then
  echo "[lifecycle-hook] Latest state is available at $STATE_FILE"
else
  echo "[lifecycle-hook] No state file exists yet at $STATE_FILE"
fi
echo "[lifecycle-hook] Done. Container will now terminate."
