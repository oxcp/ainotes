"""Convert the rendered session into an independent, non-snapshot warm pool."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

import yaml

from sandbox_timing import timing_table


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("replicas", type=int)
    parser.add_argument("--apply", type=Path, help="Save manifests here, then apply and wait for readiness.")
    parser.add_argument("--timeout", default="10m")
    args = parser.parse_args()
    if args.replicas < 1 or (args.apply is not None and args.replicas < 50):
        parser.error("Replicas must be positive; creating a warm pool requires at least 50.")
    session = next(document for document in yaml.safe_load_all(sys.stdin)
                   if document["kind"] == "Sandbox")
    namespace = session["metadata"]["namespace"]
    template = session["spec"]["podTemplate"]
    template["metadata"]["labels"]["app"] = "agent-warm"
    document = yaml.safe_dump_all(
        [
            {
                "apiVersion": "extensions.agents.x-k8s.io/v1beta1",
                "kind": "SandboxTemplate",
                "metadata": {"name": "agent-template", "namespace": namespace},
                "spec": {"podTemplate": template},
            },
            {
                "apiVersion": "extensions.agents.x-k8s.io/v1beta1",
                "kind": "SandboxWarmPool",
                "metadata": {"name": "agent-pool", "namespace": namespace},
                "spec": {
                    "replicas": args.replicas,
                    "sandboxTemplateRef": {"name": "agent-template"},
                },
            },
        ],
        sort_keys=False,
    )
    if args.apply is None:
        sys.stdout.write(document)
        return
    args.apply.write_text(document, encoding="utf-8")
    started = time.monotonic()
    subprocess.run(["kubectl", "apply", "-f", str(args.apply)], check=True)
    submitted = time.monotonic()
    subprocess.run([
        "kubectl", "-n", namespace, "wait", f"--for=jsonpath={{.status.readyReplicas}}={args.replicas}",
        "sandboxwarmpool/agent-pool", f"--timeout={args.timeout}",
    ], check=True)
    completed = time.monotonic()
    print(timing_table(args.replicas, submitted - started, completed - started), flush=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(f"ERROR: Kubernetes command failed with exit status {error.returncode}.", file=sys.stderr)
        sys.exit(error.returncode)
    except KeyboardInterrupt:
        print("Interrupted: submitted warm-pool resources are retained.", file=sys.stderr)
        sys.exit(130)
