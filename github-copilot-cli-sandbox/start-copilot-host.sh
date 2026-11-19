#!/usr/bin/env bash
set +x
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 <region> <subscription-id> <resource-group> <sandbox-group> <sandbox-id> <host-name>" >&2
  exit 2
fi

region=$1
subscription=$2
resource_group=$3
sandbox_group=$4
sandbox_id=$5
host_name=$6
guid='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'

if [[ ! $region =~ ^[a-z0-9]+$ || ! $subscription =~ $guid || ! $sandbox_id =~ $guid ]]; then
  echo "Invalid region, subscription ID, or sandbox ID." >&2
  exit 2
fi
if [[ -z $resource_group || $resource_group == . || $resource_group == .. ||
      -z $sandbox_group || $sandbox_group == . || $sandbox_group == .. || -z $host_name ]]; then
  echo "Resource group, sandbox group, and host name must be nonempty." >&2
  exit 2
fi

for cmd in az curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

python_cmd=
for candidate in python python3; do
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    python_cmd=$candidate
    break
  fi
done
if [[ -z $python_cmd ]]; then
  echo "Python 3.8 or later is required." >&2
  exit 1
fi

if [[ -z ${COPILOT_GITHUB_TOKEN:-} ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "Log in with gh, or set COPILOT_GITHUB_TOKEN." >&2
    exit 1
  fi
  COPILOT_GITHUB_TOKEN=$(gh auth token --hostname github.com | tr -d '\r\n') || {
    echo "Failed to get the GitHub token. Run gh auth login first." >&2
    exit 1
  }
fi
ADC_ACCESS_TOKEN=$(az account get-access-token \
  --subscription "$subscription" \
  --resource https://management.azuredevcompute.io \
  --query accessToken -o tsv | tr -d '\r\n') || {
  echo "Failed to get an ADC access token. Run az login first." >&2
  exit 1
}
if [[ -z $COPILOT_GITHUB_TOKEN || -z $ADC_ACCESS_TOKEN ||
      $COPILOT_GITHUB_TOKEN == *$'\n'* || $COPILOT_GITHUB_TOKEN == *$'\r'* ]]; then
  echo "A nonempty GitHub token and ADC access token are required." >&2
  exit 1
fi
export COPILOT_GITHUB_TOKEN ADC_ACCESS_TOKEN
export COPILOT_WORKSPACE="${COPILOT_WORKSPACE:-/workspaces/copilot-host}"
if [[ ${MSYS2_ENV_CONV_EXCL:-} != '*' ]]; then
  export MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+$MSYS2_ENV_CONV_EXCL;}COPILOT_WORKSPACE;COPILOT_GITHUB_TOKEN;ADC_ACCESS_TOKEN"
fi

# Pass both tokens to curl through stdin, not command-line arguments or a local file.
MSYS2_ARG_CONV_EXCL='*' "$python_cmd" - "$region" "$subscription" "$resource_group" "$sandbox_group" "$sandbox_id" "$host_name" <<'PY' |
import json
import os
import sys
from urllib.parse import quote

region, subscription, resource_group, sandbox_group, sandbox_id, host_name = sys.argv[1:]
url = (
    f"https://management.{region}.azuredevcompute.io"
    f"/subscriptions/{quote(subscription, safe='')}"
    f"/resourceGroups/{quote(resource_group, safe='')}"
    f"/sandboxGroups/{quote(sandbox_group, safe='')}"
    f"/sandboxes/{quote(sandbox_id, safe='')}/executeShellCommand"
    "?api-version=2026-02-01-preview"
)
command = r'''set -eu
: "${HOME:?HOME is required}"
: "${COPILOT_GITHUB_TOKEN:?GitHub token is required}"
: "${COPILOT_ENVIRONMENT_NAME:?Host name is required}"
: "${COPILOT_WORKSPACE:?Workspace is required}"

for cmd in node copilot; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command in sandbox: $cmd" >&2
    exit 1
  fi
done

node <<'NODE'
const fs = require("fs");
const path = require("path");
for (const pid of fs.readdirSync("/proc").filter(name => /^\d+$/.test(name))) {
  try {
    const args = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0");
    const binary = path.basename(args[0]);
    const script = path.basename(args[1] || "");
    if ((binary === "copilot" || (binary === "node" && script === "copilot")) &&
        args.some(arg => arg === "--host-environment" || arg.startsWith("--host-environment="))) {
      console.error(`Existing Copilot host process ${pid} found; not starting another host.`);
      process.exit(1);
    }
  } catch (error) {
    if (error.code !== "ENOENT" && error.code !== "EACCES" &&
        error.code !== "EPERM" && error.code !== "ESRCH") throw error;
  }
}
NODE

umask 077
state_dir="$HOME/.copilot-host"
mkdir -p "$state_dir" "$COPILOT_WORKSPACE"
chmod 700 "$state_dir"
pid_file="$state_dir/host.pid"
log_file="$state_dir/host.log"

is_running() {
  kill -0 "$1" 2>/dev/null &&
    ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null
}

if [ -f "$pid_file" ]; then
  old_pid=$(cat "$pid_file")
  case "$old_pid" in
    ''|*[!0-9]*) echo "Invalid PID file: $pid_file; inspect it before retrying." >&2; exit 1 ;;
  esac
  if is_running "$old_pid"; then
    echo "PID $old_pid from $pid_file is still running; not starting another host." >&2
    exit 1
  fi
fi

copilot config ahpEnvironment.allowCreatingNewSessions true
cd "$COPILOT_WORKSPACE"
node - "$state_dir" <<'NODE'
const fs = require("fs");
const { spawn } = require("child_process");
const path = require("path");

const stateDir = process.argv[2];
const log = fs.openSync(path.join(stateDir, "host.log"), "a", 0o600);
const child = spawn("copilot", [
  "--no-auto-update",
  "--host-environment", process.env.COPILOT_ENVIRONMENT_NAME,
  "--log-level", "debug"
], { cwd: process.cwd(), detached: true, stdio: ["ignore", log, log], env: process.env });

if (!child.pid) {
  console.error("Failed to start Copilot host; inspect the host log.");
  process.exit(1);
}
fs.writeFileSync(path.join(stateDir, "host.pid"), String(child.pid), { mode: 0o600 });
fs.closeSync(log);
child.unref();
NODE

pid=$(cat "$pid_file")
sleep 2
if ! is_running "$pid"; then
  echo "Copilot host exited during startup; inspect $log_file." >&2
  exit 1
fi
echo "Copilot host process started: PID $pid"
echo "Host log: $log_file"
echo "Process started does not yet mean the environment is online; check its log and heartbeat."
'''
body = json.dumps({
    "command": command,
    "environment": {
        "COPILOT_GITHUB_TOKEN": os.environ["COPILOT_GITHUB_TOKEN"],
        "COPILOT_GH_HOST": "github.com",
        "GH_HOST": "github.com",
        "COPILOT_ENVIRONMENT_NAME": host_name,
        "COPILOT_WORKSPACE": os.environ["COPILOT_WORKSPACE"],
    },
}, separators=(",", ":"))
for key, value in (
    ("url", url),
    ("request", "POST"),
    ("header", "Authorization: Bearer " + os.environ["ADC_ACCESS_TOKEN"]),
    ("header", "Content-Type: application/json"),
    ("data-binary", body),
):
    print(f"{key} = {json.dumps(value)}")
PY
curl --silent --show-error --fail --config - |
"$python_cmd" -c '
import json
import sys

try:
    result = json.load(sys.stdin)
except (ValueError, UnicodeError):
    print("ADC did not return a valid executeShellCommand response.", file=sys.stderr)
    sys.exit(1)

if not isinstance(result, dict) or type(result.get("exitCode")) is not int:
    print("ADC response is missing an exit code.", file=sys.stderr)
    sys.exit(1)
if result.get("stdout"):
    sys.stdout.write(result["stdout"])
if result.get("stderr"):
    sys.stderr.write(result["stderr"])
if result["exitCode"] != 0:
    print("Remote command failed with exit code {}.".format(result["exitCode"]), file=sys.stderr)
    sys.exit(1)
'
