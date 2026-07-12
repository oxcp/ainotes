#!/usr/bin/env bash
# deploy.sh — Module 3 compatibility entrypoint
#
# Module-03 mapping (current):
#   - Solution A: ACA Sandboxes -> ./sandbox-deploy.sh
#   - Solution B: ACA Dynamic Sessions -> ./dynamic-session-deploy.sh
#
# This wrapper preserves the historical `./deploy.sh` command and routes to
# Solution A by default.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Module 3 deploy wrapper"
echo "Routing to Solution A (ACA Sandboxes): ./sandbox-deploy.sh"
exec bash "${SCRIPT_DIR}/sandbox-deploy.sh" "$@"
