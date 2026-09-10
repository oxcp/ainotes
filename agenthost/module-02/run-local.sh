#!/usr/bin/env bash
# Load machine-specific package settings before azd installs dependencies.
set -eu

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# This is a local shell configuration file, separate from the deployed agent.
if [[ -f .env.local ]]; then
  set -a
  source ./.env.local
  set +a
fi

# uv does not read pip's configuration. Give both installers the same default
# index when configured here; otherwise preserve their existing settings.
if [[ -n "${AGENT_PYTHON_INDEX_URL:-}" ]]; then
  export PIP_INDEX_URL="$AGENT_PYTHON_INDEX_URL"
  export UV_DEFAULT_INDEX="$AGENT_PYTHON_INDEX_URL"
  export UV_INDEX_URL="$AGENT_PYTHON_INDEX_URL"
fi

if [[ -n "${AGENT_WHEELHOUSE:-}" ]]; then
  if [[ ! -d "$AGENT_WHEELHOUSE" ]]; then
    printf '%s\n' 'AGENT_WHEELHOUSE must point to an existing package directory.' >&2
    exit 1
  fi
  # azd changes to agent-src before installing requirements.
  WHEELHOUSE_DIR="$(cd -- "$AGENT_WHEELHOUSE" && pwd)"
  # pip splits FIND_LINKS on whitespace. Use a file URL for paths with spaces.
  WHEELHOUSE_DIR="${WHEELHOUSE_DIR//%/%25}"
  WHEELHOUSE_DIR="${WHEELHOUSE_DIR// /%20}"
  WHEELHOUSE_DIR="${WHEELHOUSE_DIR//#/%23}"
  WHEELHOUSE_DIR="${WHEELHOUSE_DIR//\?/%3F}"
  WHEELHOUSE_DIR="${WHEELHOUSE_DIR//$'\t'/%09}"
  WHEELHOUSE_DIR="${WHEELHOUSE_DIR//$'\r'/%0D}"
  WHEELHOUSE_DIR="${WHEELHOUSE_DIR//$'\n'/%0A}"
  export PIP_FIND_LINKS="file://$WHEELHOUSE_DIR"
  export UV_FIND_LINKS="$PIP_FIND_LINKS"
fi

case "${AGENT_PACKAGES_OFFLINE:-false}" in
  true|1)
    export PIP_NO_INDEX=1
    export UV_OFFLINE=1
    export UV_PYTHON_DOWNLOADS=never
    ;;
  false|0) ;;
  *)
    printf '%s\n' 'AGENT_PACKAGES_OFFLINE must be true, false, 1, or 0.' >&2
    exit 1
    ;;
esac

exec azd ai agent run "$@"
