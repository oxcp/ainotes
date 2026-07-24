#!/usr/bin/env bash
set -euo pipefail
log() { printf '[%s] %s\n' "$1" "$2"; }
require_env() { [[ -n "${!1:-}" ]] || { log ERROR "Missing $1"; exit 1; }; }
