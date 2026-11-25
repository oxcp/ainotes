"""Measure warm-pool claims, then create UID-scoped Services and Gateway routes."""
import copy
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

import yaml

from sandbox_timing import timing_table
from sandbox_network import route_template, sandbox_route, sandbox_service


PROGRESS_INTERVAL_SECONDS = 5.0
BATCH_LABEL = "agent-lab/claim-batch"
CLAIM_UID_LABEL = "agents.x-k8s.io/claim-uid"


def write_claim_log(text: str) -> None:
    log_path = Path(__file__).resolve().parents[1] / ".lab" / "claim.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as log:
        log.write(text + "\n")


def wait_for_route_confirmation() -> None:
    if not sys.stdin.isatty():
        raise RuntimeError("Route creation requires an interactive terminal; rerun with --route for automation. "
                           "Claims are retained.")
    import termios
    import tty

    descriptor = sys.stdin.fileno()
    previous = termios.tcgetattr(descriptor)
    try:
        tty.setcbreak(descriptor)
        print("Press any key to create Sandbox Services and HTTPRoutes (Ctrl+C to stop).", flush=True)
        if not os.read(descriptor, 1):
            raise RuntimeError("Terminal input closed; Claims are retained without route creation.")
    finally:
        termios.tcsetattr(descriptor, termios.TCSADRAIN, previous)


def kubectl(namespace: str, arguments: list[str]) -> dict:
    result = subprocess.run(
        ["kubectl", "-n", namespace, *arguments],
        text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)


def pod_state(pod: dict) -> str:
    if pod["metadata"].get("deletionTimestamp"):
        return "Terminating"
    status = pod.get("status", {})
    if any(condition.get("type") == "Ready" and condition.get("status") == "True"
           for condition in status.get("conditions", [])):
        return "Ready"
    for container in status.get("initContainerStatuses", []):
        waiting = container.get("state", {}).get("waiting", {})
        if waiting.get("reason"):
            return "Init:" + waiting["reason"]
    for container in status.get("containerStatuses", []):
        waiting = container.get("state", {}).get("waiting", {})
        if waiting.get("reason"):
            return waiting["reason"]
    phase = status.get("phase", "Pending")
    return "RunningNotReady" if phase == "Running" else phase


def state_counts(names: list[str], claims: list[dict], sandboxes: list[dict],
                 pods: list[dict]) -> Counter:
    claims_by_name = {claim["metadata"]["name"]: claim for claim in claims}
    sandboxes_by_name = {sandbox["metadata"]["name"]: sandbox for sandbox in sandboxes}
    pods_by_owner = defaultdict(list)
    for pod in pods:
        for owner in pod["metadata"].get("ownerReferences", []):
            if owner.get("controller") and owner.get("kind") == "Sandbox":
                pods_by_owner[owner["uid"]].append(pod)
    counts = Counter()
    for name in names:
        claim = claims_by_name.get(name)
        if claim is None:
            counts["ClaimMissing"] += 1
            continue
        sandbox_name = claim.get("status", {}).get("sandbox", {}).get("name")
        if not sandbox_name:
            counts["Unassigned"] += 1
            continue
        sandbox = sandboxes_by_name.get(sandbox_name)
        owned = [] if sandbox is None else pods_by_owner[sandbox["metadata"]["uid"]]
        active = [pod for pod in owned if not pod["metadata"].get("deletionTimestamp")]
        if len(active) > 1:
            raise RuntimeError(f"Claim {name} has multiple active Pods; cannot measure one claimed session.")
        if active:
            counts[pod_state(active[0])] += 1
        else:
            counts["Terminating" if owned else "PodNotCreated"] += 1
    return counts


def print_counts(counts: Counter, requested: int) -> None:
    print(f"Ready Pods: {counts['Ready']}/{requested}", flush=True)
    print("Pod state counts:", flush=True)
    for state, count in sorted(counts.items()):
        if count:
            print(f"  {state}: {count}", flush=True)


def create_resources(namespace: str, resources: list[dict]) -> None:
    kind = resources[0]["kind"]
    names = [resource["metadata"]["name"] for resource in resources]
    document = yaml.safe_dump({"apiVersion": "v1", "kind": "List", "items": resources}, sort_keys=False)
    created = subprocess.run(
        ["kubectl", "-n", namespace, "create", "-f", "-", "-o", "name"],
        input=document,
        text=True, capture_output=True, check=True,
    )
    returned_names = [line.partition("/")[2] for line in created.stdout.splitlines() if line.strip()]
    if len(returned_names) != len(names) or set(returned_names) != set(names):
        raise RuntimeError(f"{kind} creation did not return every requested {kind}; inspect the printed batch.")


def create_claim_services(namespace: str, names: list[str], batch: str) -> tuple[list[dict], float]:
    started = time.monotonic()
    print("Creating per-claim ClusterIP Services outside the claim readiness measurement.", flush=True)
    response = kubectl(namespace, [
        "get", "sandboxclaims", "-l", f"{BATCH_LABEL}={batch}", "-o", "json",
    ])
    claims_by_name = {claim["metadata"]["name"]: claim for claim in response["items"]}
    services = []
    for name in names:
        claim = claims_by_name.get(name)
        if claim is None:
            raise RuntimeError(f"Claim {name} is missing; cannot create its Service.")
        uid = claim["metadata"]["uid"]
        if not isinstance(uid, str) or not uid:
            raise ValueError(f"Claim {name} has no valid UID; cannot select its Pod.")
        sandbox_name = claim.get("status", {}).get("sandbox", {}).get("name")
        if not isinstance(sandbox_name, str) or not sandbox_name:
            raise ValueError(f"Claim {name} has no assigned Sandbox name; cannot create its Service.")
        services.append(sandbox_service(
            sandbox_name, namespace, claim, {BATCH_LABEL: batch}, {CLAIM_UID_LABEL: uid},
        ))
    create_resources(namespace, services)
    elapsed = time.monotonic() - started
    print(f"Service setup elapsed: {elapsed:.3f}s (excluded from Claim elapsed).", flush=True)
    print(f"Created {len(services)} claim Services (ClusterIP, port 80 -> 8080):", flush=True)
    write_claim_log("\n".join(
        f"Service {service['metadata']['name']} -> Claim "
        f"{service['metadata']['ownerReferences'][0]['name']} "
        f"(UID {service['spec']['selector'][CLAIM_UID_LABEL]})"
        for service in services
    ))
    return services, elapsed


def create_claim_routes(namespace: str, services: list[dict]) -> float:
    template = route_template()
    gateway_name = template["spec"]["parentRefs"][0]["name"]
    started = time.monotonic()
    print("Creating per-claim HTTPRoutes outside the claim readiness measurement.", flush=True)
    kubectl(namespace, ["get", "gateway", gateway_name, "-o", "json"])
    routes = [sandbox_route(service, template) for service in services]
    create_resources(namespace, routes)
    elapsed = time.monotonic() - started
    print(f"HTTPRoute setup elapsed: {elapsed:.3f}s (excluded from Claim elapsed).", flush=True)
    print(f"Created {len(routes)} claim HTTPRoutes (shared Gateway {gateway_name}):", flush=True)
    write_claim_log("\n".join(
        f"HTTPRoute {route['metadata']['name']}: /{route['metadata']['name']}/ -> "
        f"Service {route['metadata']['name']}:80 (prefix stripped)"
        for route in routes
    ))
    return elapsed


def ready_reserve(namespace: str, pool_name: str) -> int:
    pool = kubectl(namespace, ["get", "sandboxwarmpool", pool_name, "-o", "json"])
    available = pool.get("status", {}).get("readyReplicas", 0)
    if isinstance(available, bool) or not isinstance(available, int) or available < 0:
        raise ValueError("Warm pool status.readyReplicas must be a nonnegative integer.")
    return available


def main(requested: int, template: dict, *, auto_route: bool = False) -> int:
    if requested < 1:
        raise ValueError("Claim count must be a positive integer.")
    namespace = template["metadata"]["namespace"]
    pool_name = template["spec"]["warmPoolRef"]["name"]
    available = ready_reserve(namespace, pool_name)
    print(f"Requested claims: {requested}; available Ready reserve: {available}", flush=True)

    batch = uuid.uuid4().hex
    claims = []
    for index in range(1, requested + 1):
        claim = copy.deepcopy(template)
        claim["metadata"]["name"] = f"agent-claim-{batch}-{index}"
        claim["metadata"].setdefault("labels", {})[BATCH_LABEL] = batch
        claims.append(claim)
    names = [claim["metadata"]["name"] for claim in claims]
    print(f"Claim batch: {batch}", flush=True)
    write_claim_log(f"\nClaim batch: {batch}; namespace: {namespace}\n" + "\n".join(names))
    print("Detailed resource lists: .lab/claim.log", flush=True)
    first_count = min(requested, available)
    document = yaml.safe_dump({"apiVersion": "v1", "kind": "List", "items": claims[:first_count]}, sort_keys=False)
    claim_started = time.monotonic()
    submitted_count = 0
    submission_elapsed = 0.0
    between_batches_elapsed = 0.0
    round_number = 0
    while submitted_count < requested:
        remaining = requested - submitted_count
        next_progress = claim_started
        wait_started = time.monotonic() if available == 0 and submitted_count else None
        while available == 0:
            sampled_at = time.monotonic()
            if sampled_at >= next_progress:
                print(f"Waiting for Ready warm reserve: {sampled_at - claim_started:.3f}s elapsed; "
                      f"submitted {submitted_count}/{requested}; Ready reserve {available}, "
                      f"need at least 1 (remaining {remaining}). Press Ctrl+C to stop.", flush=True)
                next_progress = sampled_at + PROGRESS_INTERVAL_SECONDS
            time.sleep(0.25)
            available = ready_reserve(namespace, pool_name)
        if wait_started is not None:
            between_batches_elapsed += time.monotonic() - wait_started

        count = min(remaining, available)
        chunk_names = names[submitted_count:submitted_count + count]
        if submitted_count or first_count != count:
            document = yaml.safe_dump({
                "apiVersion": "v1", "kind": "List", "items": claims[submitted_count:submitted_count + count],
            }, sort_keys=False)
        round_number += 1
        print(f"Claim round {round_number}: submitting {count}; Ready reserve: {available}; "
              f"remaining after submission: {requested - submitted_count - count}", flush=True)
        write_claim_log(f"Claim round {round_number}: {count} Claims; Ready reserve: {available}")
        submission_started = time.monotonic()
        created = subprocess.run(
            ["kubectl", "-n", namespace, "create", "-f", "-", "-o", "name"],
            input=document,
            text=True, capture_output=True, check=True,
        )
        submitted = time.monotonic()
        returned_names = [line.partition("/")[2] for line in created.stdout.splitlines() if line.strip()]
        if len(returned_names) != count or set(returned_names) != set(chunk_names):
            raise RuntimeError("Submission did not return every requested claim; inspect the printed batch.")
        submission_elapsed += submitted - submission_started
        submitted_count += count
        print(f"Submission elapsed: {submission_elapsed:.3f}s", flush=True)
        print(f"Submitted {submitted_count} claims; waiting for their Pods without a script timeout. "
              "Press Ctrl+C to stop; created resources are retained.", flush=True)

        next_progress = submitted
        while True:
            current_claims = kubectl(namespace, [
                "get", "sandboxclaims", "-l", f"{BATCH_LABEL}={batch}", "-o", "json",
            ])
            sandboxes = kubectl(namespace, ["get", "sandboxes", "-o", "json"])
            pods = kubectl(namespace, [
                "get", "pods", "-l", "app=agent-warm", "-o", "json",
            ])
            counts = state_counts(names[:submitted_count], current_claims["items"], sandboxes["items"], pods["items"])
            sampled_at = time.monotonic()
            if counts["Ready"] == submitted_count:
                print(f"Claim round {round_number} Ready: {submitted_count}/{requested} submitted Pods.", flush=True)
                break
            if sampled_at >= next_progress:
                print(f"Waiting for claimed Pods: {sampled_at - submitted:.3f}s elapsed.", flush=True)
                print_counts(counts, submitted_count)
                next_progress = sampled_at + PROGRESS_INTERVAL_SECONDS
            time.sleep(0.25)
        if submitted_count < requested:
            available = ready_reserve(namespace, pool_name)

    print("All requested Pods are Ready.", flush=True)
    elapsed = sampled_at - claim_started
    summary = timing_table(requested, submission_elapsed, elapsed, between_batches=between_batches_elapsed)
    print("Claim timing (Services and HTTPRoutes excluded):", flush=True)
    print(summary, flush=True)
    print_counts(counts, requested)
    write_claim_log(f"Claim elapsed: {elapsed:.3f}s; average per Ready Pod: {elapsed / requested:.3f}s")
    write_claim_log(summary)
    if not auto_route:
        wait_for_route_confirmation()
    services, service_elapsed = create_claim_services(namespace, names, batch)
    route_elapsed = create_claim_routes(namespace, services)
    summary = timing_table(requested, submission_elapsed, elapsed, between_batches=between_batches_elapsed,
                           service_setup=service_elapsed, route_setup=route_elapsed)
    print("Claim and network setup timing (user confirmation wait excluded):", flush=True)
    print(summary, flush=True)
    write_claim_log(summary)
    return 0


if __name__ == "__main__":
    try:
        template = yaml.safe_load(Path(sys.argv[2]).read_text(encoding="utf-8"))
        template["metadata"]["namespace"] = os.environ["NAMESPACE"]
        sys.exit(main(int(sys.argv[1]), template, auto_route="--route" in sys.argv[3:]))
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr.rstrip(), file=sys.stderr)
        print(f"ERROR: Kubernetes command failed with exit status {error.returncode}.", file=sys.stderr)
        sys.exit(error.returncode)
    except KeyboardInterrupt:
        print("Interrupted: created Claims, Services and HTTPRoutes are retained; inspect the printed batch.",
              file=sys.stderr)
        sys.exit(130)
    except (ValueError, KeyError, RuntimeError, OSError, yaml.YAMLError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
