#!/usr/bin/env bash
# 02-verify-runtime.sh — Verify the Kata v2 pool, RuntimeClass and node readiness
#
# Usage: bash scripts/02-verify-runtime.sh
# Configuration: .env, loaded by common.sh (override with CONFIG_FILE).
# Prerequisites: provisioned AKS cluster and kubectl.

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]:-$0}")/common.sh"

# ── [1/3] Verify the preview feature, connect and validate the pool ────────────
lab_step 1/3 "Verify the preview feature, connect and validate the pool"
feature_state="$(kata_feature_state)"
[[ "$feature_state" == Registered ]] ||
  die "KataVMIsolationV2Preview is '$feature_state'. Register it, wait for Registered, refresh Microsoft.ContainerService, then verify a newly provisioned Kata pool."
echo "KataVMIsolationV2Preview is Registered."
connect
echo "Reading node pool $NODEPOOL_NAME configuration..."
az aks nodepool show \
  -g "$RESOURCE_GROUP" \
  --cluster-name "$CLUSTER_NAME" \
  -n "$NODEPOOL_NAME" \
  -o json > "$ROOT/.lab/pool.json"

python3 - "$ROOT/.lab/pool.json" <<'PY'
import json
import re
import sys
p = json.load(open(sys.argv[1]))
assert p["workloadRuntime"] in ("KataMshvVmIsolation", "KataVmIsolation"), "Pool must enable Pod sandboxing"
assert p.get("osSku", p.get("osSKU")) == "AzureLinux", "AzureLinux required"
assert re.fullmatch(r"Standard_(?:D\d+(?:as|ads|als|alds)|E\d+(?:as|ads)|F\d+(?:als|as|ams))_v6", p["vmSize"]), "Unsupported v6 VM family"
assert p["count"] >= 2, "Two Kata nodes required"
m = re.search(r"(\d{6})\.(\d+)\.(\d+)$", p["nodeImageVersion"])
assert m and tuple(map(int, m.groups())) >= (202610, 30, 1), "Node image 202610.30.1+ required"
print("Pool runtime, OS, VM family, count and node image passed.")
print(f'Runtime={p["workloadRuntime"]}, VM={p["vmSize"]}, nodes={p["count"]}, image={p["nodeImageVersion"]}')
PY

# ── [2/3] Require the Kata v2 RuntimeClass and genuine capability labels ────────
lab_step 2/3 "Require the Kata v2 RuntimeClass and genuine capability labels"
echo "Checking RuntimeClass kata-vm-isolation-v2 and Kata v2 capability labels..."
handler="$(kubectl get runtimeclass kata-vm-isolation-v2 --ignore-not-found -o jsonpath='{.handler}')"
if [[ "$handler" != kata-v2 ]]; then
  echo "Available RuntimeClasses and current Kata pool capability labels:"
  kubectl get runtimeclasses -o custom-columns=NAME:.metadata.name,HANDLER:.handler
  kubectl get nodes -l "agentpool=$NODEPOOL_NAME" \
    -L kubernetes.azure.com/kata-vm-isolation-v2,kubernetes.azure.com/kata-vm-isolation \
    -o wide
  die "Kata v2 RuntimeClass handler is absent or incompatible. Check regional availability and replace a pre-v2 pool after preview registration; do not add labels or create a RuntimeClass manually."
fi

selector="kubernetes.azure.com/kata-vm-isolation-v2=true,agentpool=$NODEPOOL_NAME"
expected="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["count"])' "$ROOT/.lab/pool.json")"
actual="$(kubectl get nodes -l "$selector" -o go-template='{{len .items}}')"
[[ "$actual" == "$expected" ]] || die "Only $actual/$expected nodes have the Kata v2 capability. Do not add the label manually."
echo "Kata v2 capability verified on $actual/$expected nodes."

# ── [3/3] Wait for the Kata nodes and display their placement ───────────────────
lab_step 3/3 "Wait for the Kata nodes and display their placement"
started=$SECONDS
deadline=$((SECONDS + TIMEOUT_SECONDS))
while true; do
  remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || die "Kata nodes did not become Ready within $TIMEOUT."
  nodes="$(kubectl get nodes -l "$selector" -o json --request-timeout="${remaining}s")"
  progress="$(python3 - "$nodes" "$expected" <<'PY'
import json
import sys

nodes = json.loads(sys.argv[1])["items"]
assert len(nodes) == int(sys.argv[2]), "Kata v2 node count changed while waiting for readiness"
ready = sum(
    any(c["type"] == "Ready" and c["status"] == "True" for c in node["status"].get("conditions", []))
    for node in nodes
)
print(ready, len(nodes))
PY
)"
  read -r ready total <<< "$progress"
  echo "[$(date '+%H:%M:%S')] Kata nodes Ready: $ready/$total (elapsed $((SECONDS - started))s; limit $TIMEOUT)"
  if [[ "$ready" == "$total" ]]; then
    break
  fi
  remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || die "Kata nodes did not become Ready within $TIMEOUT."
  delay=30
  if (( remaining < delay )); then
    delay=$remaining
  fi
  sleep "$delay"
done
kubectl get nodes -l "$selector" -L node.kubernetes.io/instance-type -o wide
