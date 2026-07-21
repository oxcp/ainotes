#!/usr/bin/env bash
# lifecycle-hook.sh — preStop hook for the agent-sandbox Sandbox pod.
# Runs on SIGTERM (hibernate / delete / rolling update).
#
# State model: the agent persists conversation state DIRECTLY to Azure Blob
# Storage as <AGENT_ID>.json on EVERY change (after each chat turn). Blob is the
# single source of truth, so there is no hot cache to flush at shutdown — the
# latest state is already durable in Blob. This hook therefore only logs; keep
# it as an extension point (e.g. emit metrics or tag a final snapshot).
#
# Wired via agent-sandbox.yaml:
#   lifecycle: { preStop: { exec: { command: ["/app/lifecycle-hook.sh"] } } }
#
# Environment (injected by agent-sandbox.yaml):
#   AGENT_ID               — unique agent identifier
#   AGENT_STORAGE_ACCOUNT  — Azure Blob Storage account name
#   AGENT_BLOB_CONTAINER   — Blob container (e.g. "agent-state")

set -euo pipefail

AGENT_ID="${AGENT_ID:-unknown}"
STORAGE_ACCOUNT="${AGENT_STORAGE_ACCOUNT:-}"
CONTAINER="${AGENT_BLOB_CONTAINER:-agent-state}"

echo "[lifecycle-hook] preStop for agent: $AGENT_ID"
echo "[lifecycle-hook] State is persisted to Blob on every change; nothing to flush."
if [[ -n "$STORAGE_ACCOUNT" ]]; then
  echo "[lifecycle-hook] Latest state already durable at ${STORAGE_ACCOUNT}/${CONTAINER}/${AGENT_ID}.json"
fi
echo "[lifecycle-hook] Done. Container will now terminate."
