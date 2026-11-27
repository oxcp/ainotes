#!/usr/bin/env bash
# Report allocatable resources and scheduled Pod requests for an AKS node pool.
#
# Usage: bash scripts/check-node-resources.sh [--pool katapool] [--context <context>]
# Prerequisites: kubectl, Python 3 and a prepared kubectl context.
# This script only reads Kubernetes resources; it does not load .env or log in.

set -euo pipefail

# --- Select the node pool and Kubernetes context ---
pool="${NODEPOOL_NAME:-katapool}"
context=""

while (( $# > 0 )); do
  case "$1" in
    --pool|--context)
      if [[ "$#" -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo "ERROR: $1 requires a value." >&2
        exit 1
      fi
      if [[ "$1" == --pool ]]; then
        pool="$2"
      else
        context="$2"
      fi
      shift 2
      ;;
    --help|-h)
      echo "Usage: bash scripts/check-node-resources.sh [--pool katapool] [--context <context>]"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! "$pool" =~ ^[a-z][a-z0-9]{0,11}$ ]]; then
  echo "ERROR: Invalid AKS node pool name: $pool" >&2
  exit 1
fi

# --- Check local tools without changing cluster configuration ---
for tool in kubectl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: $tool" >&2
    exit 1
  fi
done

if [[ -z "$context" ]]; then
  context="$(kubectl config current-context)"
fi
if [[ -z "$context" ]]; then
  echo "ERROR: No Kubernetes context selected. Pass --context <context>." >&2
  exit 1
fi

# --- Read node allocations and print a complete report ---
python3 - "$context" "$pool" <<'PY'
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from decimal import Decimal

context, pool = sys.argv[1:]
gib = Decimal(1024 ** 3)
scales = {
    "": Decimal(1), "n": Decimal("1e-9"), "u": Decimal("1e-6"),
    "m": Decimal("1e-3"), "k": Decimal("1e3"), "K": Decimal("1e3"),
    "M": Decimal("1e6"), "G": Decimal("1e9"), "T": Decimal("1e12"),
    "P": Decimal("1e15"), "E": Decimal("1e18"),
}
scales.update({unit + "i": Decimal(1024 ** power)
               for power, unit in enumerate("KMGTPE", 1)})


def quantity(value: str) -> Decimal:
    match = re.fullmatch(r"([+]?(?:\d+(?:\.\d*)?|\.\d+))([a-zA-Z]*|[eE][+-]?\d+)", value)
    if match is None:
        raise ValueError(f"Invalid Kubernetes resource quantity: {value}")
    number, suffix = match.groups()
    if re.fullmatch(r"[eE][+-]?\d+", suffix):
        return Decimal(number + suffix)
    if suffix not in scales:
        raise ValueError(f"Unsupported Kubernetes resource unit: {value}")
    return Decimal(number) * scales[suffix]


def kubectl(*arguments: str) -> str:
    return subprocess.run(
        ["kubectl", "--context", context, "--request-timeout=30s", *arguments],
        check=True, capture_output=True, text=True, timeout=60,
    ).stdout


def request(description: str, resource: str) -> Decimal:
    allocation = re.search(r"(?m)^Allocated resources:\s*$", description)
    if allocation is None:
        raise ValueError("Node description has no Allocated resources section")
    match = re.search(
        rf"(?m)^\s+{resource}\s+(\S+)\s+\(\d+%\)",
        description[allocation.end():],
    )
    if match is None:
        raise ValueError(f"Node description has no allocated {resource} requests")
    return quantity(match[1])


def row(name: str, cpu: Decimal, cpu_requests: Decimal,
        memory: Decimal, memory_requests: Decimal) -> list[str]:
    return [
        name, f"{cpu:.3f}", f"{cpu_requests:.3f}", f"{cpu_requests / cpu * 100:.1f}%",
        f"{memory / gib:.3f}", f"{memory_requests / gib:.3f}",
        f"{memory_requests / memory * 100:.1f}%",
    ]


try:
    nodes = json.loads(kubectl(
        "get", "nodes", "-l", f"kubernetes.azure.com/agentpool={pool}", "-o", "json",
    ))["items"]
    if not nodes:
        raise ValueError(f"No nodes found in node pool {pool}")
    allocations = []
    for node in sorted(nodes, key=lambda item: item["metadata"]["name"]):
        name = node["metadata"]["name"]
        allocatable = node["status"]["allocatable"]
        cpu, memory = quantity(allocatable["cpu"]), quantity(allocatable["memory"])
        if cpu <= 0 or memory <= 0:
            raise ValueError(f"Node {name} has nonpositive allocatable CPU or memory")
        description = kubectl("describe", "node", name)
        allocations.append((name, cpu, request(description, "cpu"),
                            memory, request(description, "memory")))
    totals = [sum((item[index] for item in allocations), Decimal(0))
              for index in range(1, 5)]
    rows = [
        ["Node", "CPU alloc", "CPU requests", "CPU %", "Mem alloc", "Mem requests", "Mem %"],
        *(row(*item) for item in allocations),
        row("TOTAL", *totals),
    ]
    widths = [max(len(values[index]) for values in rows) for index in range(7)]
    separator = "+-" + "-+-".join("-" * width for width in widths) + "-+"
    print(f"Context: {context} | Node pool: {pool} | Nodes: {len(nodes)}")
    print(f"Collected at: {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    print("CPU: cores | Memory: GiB | Requests: all namespaces, not live usage")
    print(separator)
    for index, values in enumerate(rows):
        print("| " + " | ".join(value.ljust(width) if column == 0 else value.rjust(width)
                                for column, (value, width) in enumerate(zip(values, widths))) + " |")
        if index == 0 or index == len(rows) - 2:
            print(separator)
    print(separator)
    print(f"Remaining request capacity: CPU {totals[0] - totals[1]:.3f} cores | "
          f"Memory {(totals[2] - totals[3]) / gib:.3f} GiB")
    print("Read-only, sequential snapshot; allocations can change during collection.")
except subprocess.CalledProcessError as error:
    print(f"ERROR: kubectl failed (exit {error.returncode}): {error.stderr.strip()}", file=sys.stderr)
    sys.exit(1)
except subprocess.TimeoutExpired as error:
    print(f"ERROR: Kubernetes query timed out: {error}", file=sys.stderr)
    sys.exit(1)
except (OSError, ValueError, KeyError) as error:
    print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)
PY
