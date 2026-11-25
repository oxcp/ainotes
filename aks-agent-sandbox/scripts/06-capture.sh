#!/usr/bin/env bash
# 06-capture.sh — Capture a named Sandbox's Pod and wait for a restorable snapshot
#
# Usage: bash scripts/06-capture.sh <sandbox-name>
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: Ready Pod, snapshot storage config and broker access.
# Restored Pods must not specify resource limits.

set -euo pipefail

if [[ $# -ne 1 ||
      ${#1} -gt 253 ||
      ! "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  echo "Usage: bash scripts/06-capture.sh <sandbox-name>" >&2
  exit 2
fi

source_sandbox="$1"
export SOURCE_SANDBOX="$source_sandbox"
source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/4] Resolve the Sandbox's Pod and save its source identity ───────────────
lab_step 1/4 "Find the Pod controlled by Sandbox $source_sandbox"
connect
capture_name="capture-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
capture_dir="$ROOT/.lab/captures/$capture_name"
mkdir -p "$capture_dir"
kubectl -n "$NAMESPACE" get sandbox "$source_sandbox" -o json > "$capture_dir/sandbox.json"
kubectl -n "$NAMESPACE" get pods -o json > "$capture_dir/pods.json"
SOURCE_POD="$(python3 - "$capture_dir" <<'PY'
import json
import os
from pathlib import Path
import sys

directory = Path(sys.argv[1])
sandbox = json.loads((directory / "sandbox.json").read_text())
metadata = sandbox["metadata"]
if (metadata["name"] != os.environ["SOURCE_SANDBOX"]
        or metadata["namespace"] != os.environ["NAMESPACE"]
        or metadata.get("deletionTimestamp")):
    sys.exit("ERROR: Sandbox identity does not match the request or it is being deleted.")
pods = [pod for pod in json.loads((directory / "pods.json").read_text())["items"] if any(
    owner.get("kind") == "Sandbox" and owner.get("controller")
    and owner.get("apiVersion", "").startswith("agents.x-k8s.io/")
    and owner.get("name") == metadata["name"] and owner.get("uid") == metadata["uid"]
    for owner in pod["metadata"].get("ownerReferences", [])
)]
if len(pods) != 1:
    sys.exit(f"ERROR: Expected exactly one Pod controlled by Sandbox {metadata['name']}; found {len(pods)}.")
print(pods[0]["metadata"]["name"])
PY
)"
export SOURCE_POD
echo "Sandbox: $source_sandbox; resolved Pod: $SOURCE_POD"
kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready "pod/$SOURCE_POD" \
  --timeout="$TIMEOUT"
kubectl -n "$NAMESPACE" get pod "$SOURCE_POD" -o json > "$capture_dir/pod.json"
kubectl -n "$NAMESPACE" get sandbox "$source_sandbox" -o json > "$capture_dir/sandbox-current.json"

python3 - "$ROOT" "$capture_dir" "$capture_name" <<'PY'
import json
import os
from pathlib import Path
import sys
import yaml

root, directory = (Path(value) for value in sys.argv[1:3])
name = sys.argv[3]
pod = json.loads((directory / "pod.json").read_text())
metadata = pod["metadata"]
if metadata["name"] != os.environ["SOURCE_POD"] or metadata["namespace"] != os.environ["NAMESPACE"]:
    sys.exit("ERROR: Pod identity does not match the requested name and namespace.")
if metadata.get("deletionTimestamp"):
    sys.exit("ERROR: Cannot capture a terminating Pod.")
restored = (metadata.get("labels", {}).get("podsnapshot.aks.azure.com/restore") == "true"
            or "podsnapshot.aks.azure.com/restore-from" in metadata.get("annotations", {}))
if restored:
    spec = pod.get("spec", {})
    limits = {
        f"{group}/{container['name']}": container["resources"]["limits"]
        for group in ("containers", "initContainers") for container in spec.get(group, [])
        if container.get("resources", {}).get("limits")
    }
    if spec.get("resources", {}).get("limits"):
        limits["pod"] = spec["resources"]["limits"]
    if limits:
        sys.exit(
            "ERROR: AKS supports recapturing restored Pods only without resource limits. "
            f"Pod {metadata['name']} has limits: {json.dumps(limits, sort_keys=True)}. "
            "This script will not resize or recreate the running Pod. "
            "Prepare a compatible restore workload without limits before recapturing; "
            "keep source and restore resource sizing aligned."
        )
owners = [owner for owner in metadata.get("ownerReferences", [])
          if owner.get("kind") == "Sandbox" and owner.get("controller")
          and owner.get("apiVersion", "").startswith("agents.x-k8s.io/")]
sandbox = json.loads((directory / "sandbox.json").read_text())
current = json.loads((directory / "sandbox-current.json").read_text())["metadata"]
if (current.get("deletionTimestamp") or any(
        current.get(field) != sandbox["metadata"][field] for field in ("name", "namespace", "uid"))):
    sys.exit("ERROR: Sandbox identity changed or it is being deleted; capture aborted.")
if (len(owners) != 1 or owners[0].get("name") != sandbox["metadata"]["name"]
        or owners[0].get("uid") != sandbox["metadata"]["uid"]):
    sys.exit("ERROR: Pod is no longer controlled by the selected Sandbox; capture aborted.")
policy = next(document for document in yaml.safe_load_all(
    (root / "manifests" / "snapshot-policy.yaml").read_text()
) if document["kind"] == "PodSnapshotPolicy")
policy["metadata"] = {"name": name, "namespace": metadata["namespace"]}
policy["spec"]["storageConfigName"] = os.environ["STORAGE_CONFIG"]
policy["spec"]["selector"] = {"matchLabels": {"agent-lab/snapshot-source": metadata["uid"]}}
trigger = yaml.safe_load((root / "manifests" / "trigger.yaml").read_text())
trigger["metadata"] = {"name": name, "namespace": metadata["namespace"]}
trigger["spec"] = {"targetPod": metadata["name"], "policyName": name}
for filename, document in (("policy.yaml", policy), ("trigger.yaml", trigger)):
    (directory / filename).write_text(yaml.safe_dump(document, sort_keys=False))
patch = {"metadata": {
    "uid": metadata["uid"], "resourceVersion": metadata["resourceVersion"],
    "labels": {"agent-lab/snapshot-source": metadata["uid"]},
}}
(directory / "pod-patch.json").write_text(json.dumps(patch))
PY

if [[ "$source_sandbox" == agent-session ]]; then
  [[ ! -f "$ROOT/.lab/snapshot-name" ]] ||
    die "Standalone capture already recorded. Finish restore and cleanup before capturing agent-session again."
  request "$SOURCE_POD" /state > "$capture_dir/before.json"
fi

# ── [2/4] Label only this Pod and create its dedicated manual policy ───────────
lab_step 2/4 "Label Pod $SOURCE_POD and create policy $capture_name"
kubectl -n "$NAMESPACE" patch pod "$SOURCE_POD" \
  --type=merge \
  --patch "$(cat "$capture_dir/pod-patch.json")"
kubectl -n "$NAMESPACE" create -f "$capture_dir/policy.yaml"

# ── [3/4] Trigger capture and retrieve the resulting snapshot name ─────────────
lab_step 3/4 "Trigger capture $capture_name for Pod $SOURCE_POD"
kubectl -n "$NAMESPACE" create -f "$capture_dir/trigger.yaml"
kubectl -n "$NAMESPACE" wait \
  --for=condition=Triggered "podsnapshotmanualtrigger/$capture_name" \
  --timeout="$TIMEOUT"

SNAPSHOT_NAME="$(kubectl -n "$NAMESPACE" get podsnapshotmanualtrigger "$capture_name" \
  -o jsonpath='{.status.snapshotCreated.name}')"
[[ -n "$SNAPSHOT_NAME" ]] || die "Capture trigger returned no snapshot name."
export SNAPSHOT_NAME

# ── [4/4] Wait for snapshot readiness before recording it for restore ───────────
lab_step 4/4 "Wait for snapshot readiness before recording it for restore"
kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready "podsnapshot/$SNAPSHOT_NAME" \
  --timeout="$TIMEOUT"
kubectl -n "$NAMESPACE" get podsnapshot "$SNAPSHOT_NAME" -o yaml
context="$(kubectl config current-context)"
python3 "$ROOT/scripts/snapshot_mapping.py" \
  "$ROOT/.lab/snapshot-mapping" \
  "$context" \
  "$capture_dir/sandbox.json" \
  "$SNAPSHOT_NAME"
echo "Sandbox-to-snapshot association saved to .lab/snapshot-mapping."
printf '%s\n' "$SNAPSHOT_NAME" > "$capture_dir/snapshot-name"

if [[ "$source_sandbox" == agent-session ]]; then
  cp "$capture_dir/before.json" "$ROOT/.lab/before.json"
  cp "$capture_dir/sandbox.json" "$ROOT/.lab/session-source.json"
  printf '%s\n' "$SNAPSHOT_NAME" > "$ROOT/.lab/snapshot-name"
fi

echo "Captured Sandbox: $source_sandbox; Pod: $SOURCE_POD; snapshot: $SNAPSHOT_NAME"
echo "Capture records: $capture_dir"
echo "Snapshot Ready; source is still running. Inspect the Blob account/container in the status before restoring."
