#!/usr/bin/env bash
# Delete existing snapshots in one confirmed lab namespace, preserving workloads.
#
# Usage: bash scripts/08-delete-snapshots.sh --confirm-namespace <namespace>
# Configuration: Exported NAMESPACE (default agent-lab) and TIMEOUT (default 10m).
# Prerequisites: Prepared kubectl context, Python 3, running snapshot controllers/storage.
# WARNING: Deleted snapshots cannot be used to recover captured process state.

set -euo pipefail

# --- Validate the explicitly confirmed deletion scope ---
namespace="${NAMESPACE-agent-lab}"
timeout="${TIMEOUT-10m}"
if [[ "$#" -ne 2 || "${1:-}" != --confirm-namespace || "${2:-}" != "$namespace" ]]; then
  echo "ERROR: Usage: bash scripts/08-delete-snapshots.sh --confirm-namespace $namespace" >&2
  exit 2
fi
if [[ ! "$namespace" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ||
      "$namespace" == kube-* || "$namespace" == default ]]; then
  echo "ERROR: Set NAMESPACE to a dedicated non-system namespace." >&2
  exit 2
fi
if [[ ! "$timeout" =~ ^[1-9][0-9]*[smh]$ ]]; then
  echo "ERROR: Set TIMEOUT to a positive duration such as 10m." >&2
  exit 2
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
context="$(kubectl config current-context)"
[[ -n "$context" ]] || {
  echo "ERROR: Select a kubectl context before deleting snapshots." >&2
  exit 1
}

# --- Check consumers, delete snapshots normally and reconcile local mappings ---
python3 - "$ROOT" "$context" "$namespace" "$timeout" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1])
context, namespace, timeout = sys.argv[2:]
sys.path.insert(0, str(root / "scripts"))
from snapshot_mapping import read_mapping, remove_namespace_mappings


def kubectl(*arguments, seconds=45):
    result = subprocess.run(
        ["kubectl", "--context", context, "-n", namespace, *arguments],
        capture_output=True, text=True, check=True, timeout=seconds,
    )
    return result.stdout


def resources(kind):
    return json.loads(kubectl("get", kind, "-o", "json"))["items"]


def restore_intent(metadata):
    return (metadata.get("labels", {}).get("podsnapshot.aks.azure.com/restore") == "true"
            or "podsnapshot.aks.azure.com/restore-from" in metadata.get("annotations", {}))


try:
    print(f"[1/3] Check snapshot deletion safety: context={context}; namespace={namespace}", flush=True)
    mapping = root / ".lab" / "snapshot-mapping"
    read_mapping(mapping)
    for policy in resources("podsnapshotpolicies"):
        if policy.get("spec", {}).get("triggerConfig", {}).get("type") == "cron":
            raise ValueError(f"Stop/remove scheduled policy {policy['metadata']['name']} before cleanup.")
    for trigger in resources("podsnapshotmanualtriggers"):
        if not any(item.get("type") == "Triggered" and item.get("status") == "True"
                   for item in trigger.get("status", {}).get("conditions", [])):
            raise ValueError(f"Capture trigger {trigger['metadata']['name']} is incomplete; inspect it first.")
    for sandbox in resources("sandboxes"):
        if restore_intent(sandbox.get("spec", {}).get("podTemplate", {}).get("metadata", {})):
            raise ValueError(f"Sandbox {sandbox['metadata']['name']} has restore intent. "
                             "Explicitly release restore consumers before deleting snapshots.")
    for pod in resources("pods"):
        if restore_intent(pod["metadata"]):
            raise ValueError(f"Pod {pod['metadata']['name']} has restore intent. "
                             "Explicitly release restore consumers before deleting snapshots.")
    snapshots = resources("podsnapshots")
    names = [item["metadata"]["name"] for item in snapshots]
    if any(not isinstance(name, str) or re.fullmatch(r"[a-z0-9][a-z0-9.-]*", name) is None for name in names):
        raise ValueError("Invalid snapshot name returned by Kubernetes; refusing deletion.")

    print(f"[2/3] Delete {len(names)} snapshots and wait for normal finalizer cleanup", flush=True)
    if names:
        seconds = int(timeout[:-1]) * {"s": 1, "m": 60, "h": 3600}[timeout[-1]]
        output = kubectl(
            "delete", "podsnapshots", *names, "--ignore-not-found", "--wait=true", f"--timeout={timeout}",
            seconds=seconds + 15,
        )
        print(output, end="", flush=True)
    if resources("podsnapshots"):
        raise ValueError("Snapshots remain or a new capture appeared; preserve mappings and inspect before retrying.")

    print("[3/3] Remove local mappings only for the confirmed context and namespace", flush=True)
    removed = remove_namespace_mappings(mapping, context, namespace)
    marker = root / ".lab" / "snapshot-name"
    if marker.is_file() and any(
        item["sandbox"] == "agent-session" and item["snapshot"] == marker.read_text().strip()
        for item in removed
    ):
        marker.unlink()
    print(f"Snapshot cleanup complete; removed {len(removed)} local mappings. "
          "Workloads, network resources, policies, triggers and capture records were retained.")
except subprocess.CalledProcessError as error:
    print(f"ERROR: {error.stderr.strip() or str(error)}\n"
          "Cleanup stopped. Snapshots may be partially deleted; inspect resources before retrying. "
          "Do not remove finalizers or stop snapshot controllers/storage access.", file=sys.stderr)
    sys.exit(error.returncode)
except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
    print(f"ERROR: Snapshot cleanup stopped: {error}\n"
          "Inspect resources before retrying; do not remove finalizers.", file=sys.stderr)
    sys.exit(1)
PY
