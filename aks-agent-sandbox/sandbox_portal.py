"""Local browser for claimed Sandboxes using the prepared kubectl context."""
import argparse
import copy
import hmac
import ipaddress
import json
import logging
from pathlib import Path
import re
import secrets
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, build_opener

import yaml

from scripts.snapshot_mapping import read_mapping, record_snapshot
from scripts.sandbox_network import route_template, sandbox_route, sandbox_service


LOGGER = logging.getLogger("sandbox_portal")
CLAIM_UID_LABEL = "agents.x-k8s.io/claim-uid"
RESTORE_FROM = "podsnapshot.aks.azure.com/restore-from"
RESTORE_LABEL = "podsnapshot.aks.azure.com/restore"
RESTORED_POOL_LABEL = "agent-lab/restored-pool"
RESTORED_POD_LABEL = "restore-sandbox"
NAME = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")


class PortalError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def ready(resource):
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in resource.get("status", {}).get("conditions", []))


def sandbox_status(resource):
    if resource["metadata"].get("deletionTimestamp"):
        return "Terminating"
    if ready(resource):
        return "Ready"
    conditions = resource.get("status", {}).get("conditions", [])
    if any(c.get("type") == "Suspended" and c.get("status") == "True" for c in conditions):
        return "Suspended"
    if any((c.get("type") == "Ready" and c.get("status") == "False" and c.get("reason") == "Stopped")
           or (c.get("type") == "Stopped" and c.get("status") == "True") for c in conditions):
        return "Stopped"
    return "Not Ready"


class SandboxPortal:
    def __init__(self, namespace, context, gateway="sandbox-gateway", pool="agent-pool"):
        self.namespace = namespace
        self.context = context
        self.gateway = gateway
        self.pool = pool
        self.cached_state = ("", {})
        self.cached_warm = {}
        self.snapshot_mapping_path = Path(__file__).resolve().parent / ".lab" / "snapshot-mapping"
        self.wake_lock = threading.Lock()

    def kubectl(self, *arguments, document=None, timeout=45):
        command = ["kubectl", "--context", self.context, "-n", self.namespace, *arguments]
        try:
            result = subprocess.run(
                command, input=None if document is None else json.dumps(document),
                capture_output=True, text=True, check=True, timeout=timeout,
            )
        except subprocess.CalledProcessError as error:
            raise PortalError(error.stderr.strip() or "kubectl command failed") from error
        except subprocess.TimeoutExpired as error:
            raise PortalError("Kubernetes command timed out; inspect the resource before retrying.") from error
        if not result.stdout.strip() and "--ignore-not-found" in arguments:
            return {}
        return json.loads(result.stdout)

    def mapped_snapshot(self, sandbox, records=None):
        if records is None:
            records = read_mapping(self.snapshot_mapping_path)
        return next((record["snapshot"] for record in records
                     if record["context"] == self.context and record["namespace"] == self.namespace
                     and record["sandbox"] == sandbox["metadata"]["name"]
                     and record["sandbox_uid"] == sandbox["metadata"].get("uid")), None)

    def gateway_address(self):
        address, _ = self.cached_state
        if not address:
            raise PortalError("No cached Gateway IP. Reload the page to load it.")
        try:
            ip = ipaddress.ip_address(address)
        except ValueError as error:
            raise PortalError("Cached Gateway IP is invalid. Reload the page to update it.") from error
        return str(ip), f"http://[{ip}]" if ip.version == 6 else f"http://{ip}"

    def claims(self):
        return [
            c for c in self.kubectl("get", "sandboxclaims", "-o", "json")["items"]
            if not c["metadata"].get("deletionTimestamp")
            and c.get("spec", {}).get("warmPoolRef", {}).get("name") == self.pool
        ]

    def info(self):
        gateway = self.kubectl("get", "gateway", self.gateway, "-o", "json")
        ip = next((a.get("value", "") for a in gateway.get("status", {}).get("addresses", [])
                   if a.get("type", "IPAddress") == "IPAddress"), "")
        _, selections = self.cached_state
        self.cached_state = (ip, selections)
        return {"namespace": self.namespace, "context": self.context, "gateway_ip": ip}

    def claimed_state(self):
        claims = self.claims()
        sandboxes = {s["metadata"]["name"]: s for s in
                     self.kubectl("get", "sandboxes", "-o", "json")["items"]}
        entries = []
        selections = {}
        records = read_mapping(self.snapshot_mapping_path)
        for claim in claims:
            name = claim.get("status", {}).get("sandbox", {}).get("name")
            sandbox = sandboxes.get(name)
            if sandbox is None:
                continue
            if not self.owned_by_claim(sandbox, claim):
                raise PortalError(f"Sandbox {name} is not owned by its reported Claim.")
            entries.append({
                "name": name, "claim": claim["metadata"]["name"],
                "mode": sandbox.get("spec", {}).get("operatingMode", "Running"),
                "ready": sandbox_status(sandbox) == "Ready",
                "status": sandbox_status(sandbox),
                "uid": sandbox["metadata"]["uid"],
                "snapshot": self.mapped_snapshot(sandbox, records),
            })
            selections[name] = (sandbox, claim)
        assigned_count = len(entries)
        for name, sandbox in sandboxes.items():
            if (name not in selections and not sandbox["metadata"].get("deletionTimestamp")
                    and sandbox["metadata"].get("labels", {}).get(RESTORED_POOL_LABEL) == self.pool
                    and not sandbox["metadata"].get("ownerReferences")):
                entries.append({
                    "name": name, "claim": None, "restored": True,
                    "mode": sandbox.get("spec", {}).get("operatingMode", "Running"),
                    "ready": sandbox_status(sandbox) == "Ready", "status": sandbox_status(sandbox),
                    "uid": sandbox["metadata"]["uid"], "snapshot": self.mapped_snapshot(sandbox, records),
                })
                selections[name] = (sandbox, None)
        ip, _ = self.cached_state
        self.cached_state = (ip, selections)
        return {
            "claimed_count": len(entries),
            "pending_claim_count": len(claims) - assigned_count,
            "sandboxes": sorted(entries, key=lambda entry: entry["name"]),
        }

    def warm_state(self):
        sandboxes = self.kubectl("get", "sandboxes", "-o", "json")["items"]
        selections = {
            sandbox["metadata"]["name"]: sandbox for sandbox in sandboxes
            if "agents.x-k8s.io/warm-pool-sandbox" in sandbox["metadata"].get("labels", {})
        }
        records = read_mapping(self.snapshot_mapping_path)
        entries = [
            {
                "name": sandbox["metadata"]["name"],
                "mode": sandbox.get("spec", {}).get("operatingMode", "Running"),
                "ready": sandbox_status(sandbox) == "Ready",
                "status": sandbox_status(sandbox),
                "uid": sandbox["metadata"].get("uid"),
                "snapshot": self.mapped_snapshot(sandbox, records),
            }
            for sandbox in selections.values()
        ]
        self.cached_warm = selections
        return {
            "warm_count": len(entries),
            "warm_ready": sum(entry["ready"] for entry in entries),
            "warm_sandboxes": sorted(entries, key=lambda entry: entry["name"]),
        }

    def snapshot_state(self):
        records = [record for record in read_mapping(self.snapshot_mapping_path)
                   if record["context"] == self.context and record["namespace"] == self.namespace]
        return {
            "snapshot_count": len(records),
            "snapshots": sorted(records, key=lambda record: (record["snapshot"], record["sandbox"])),
        }

    @staticmethod
    def owned_by_claim(sandbox, claim):
        return any(
            owner.get("kind") == "SandboxClaim" and owner.get("uid") == claim["metadata"]["uid"]
            for owner in sandbox["metadata"].get("ownerReferences", [])
        )

    def selected(self, name):
        if not isinstance(name, str) or NAME.fullmatch(name) is None:
            raise PortalError("Invalid Sandbox name.")
        _, selections = self.cached_state
        if name in selections:
            sandbox, claim = selections[name]
            if (sandbox["metadata"].get("deletionTimestamp")
                    or (claim is not None and not self.owned_by_claim(sandbox, claim))):
                raise PortalError("Cached Sandbox ownership is invalid. Click Refresh to update it.")
            return sandbox, claim
        if name not in self.cached_warm:
            raise PortalError("Sandbox is not in the cached list. Click Refresh to update it.")
        sandbox = self.cached_warm[name]
        if sandbox["metadata"].get("deletionTimestamp"):
            raise PortalError("Cached Sandbox is being deleted. Click Refresh to update it.")
        return sandbox, None

    def health(self, root):
        try:
            with build_opener(NoRedirect).open(root + "/health", timeout=5) as response:
                return response.status, ""
        except HTTPError as error:
            return error.code, f"HTTP {error.code}"
        except (URLError, TimeoutError, OSError) as error:
            return 0, str(error)

    def snapshot_for(self, sandbox):
        metadata = sandbox.get("spec", {}).get("podTemplate", {}).get("metadata", {})
        explicit = metadata.get("annotations", {}).get(RESTORE_FROM)
        if explicit:
            snapshot = self.kubectl("get", "podsnapshot", explicit, "-o", "json")
            if not ready(snapshot) or snapshot["metadata"].get("deletionTimestamp"):
                raise PortalError("The Sandbox's explicitly configured snapshot is not Ready.")
            return snapshot["metadata"]["name"]
        name = sandbox["metadata"]["name"]
        mappings = read_mapping(self.snapshot_mapping_path)
        mapped = next((record for record in mappings
                       if record["context"] == self.context and record["namespace"] == self.namespace
                       and record["sandbox"] == name
                       and record["sandbox_uid"] == sandbox["metadata"].get("uid")), None)
        if mapped is not None:
            snapshot = self.kubectl("get", "podsnapshot", mapped["snapshot"], "-o", "json")
            if not ready(snapshot) or snapshot["metadata"].get("deletionTimestamp"):
                raise PortalError("The Sandbox's mapped snapshot is not Ready.")
            return snapshot["metadata"]["name"]
        created = sandbox["metadata"].get("creationTimestamp")
        if not created:
            raise PortalError("Sandbox creation time is missing; snapshot association cannot be verified.")
        triggers = self.kubectl("get", "podsnapshotmanualtriggers", "-o", "json")["items"]
        names = {
            trigger.get("status", {}).get("snapshotCreated", {}).get("name")
            for trigger in triggers if trigger.get("spec", {}).get("targetPod") == name
            and trigger["metadata"].get("creationTimestamp", "") >= created
        } - {None, ""}
        snapshots = self.kubectl("get", "podsnapshots", "-o", "json")["items"]
        candidates = [s for s in snapshots if s["metadata"]["name"] in names
                      and ready(s) and not s["metadata"].get("deletionTimestamp")]
        if not candidates:
            raise PortalError("No associated Ready snapshot was found. Auto-wake cannot cold-start this Sandbox.")
        latest = max(candidates, key=lambda s: s["metadata"].get("creationTimestamp", ""))
        return latest["metadata"]["name"]

    def resume(self, sandbox, claim):
        name = sandbox["metadata"]["name"]
        if sandbox.get("spec", {}).get("operatingMode") != "Suspended":
            raise PortalError("Health failed, but the cached Sandbox is not suspended. "
                              "Click Refresh if its state changed; otherwise check the app, route and Gateway.")
        if not any(c.get("type") == "Suspended" and c.get("status") == "True"
                   for c in sandbox.get("status", {}).get("conditions", [])):
            raise PortalError("Cached Sandbox suspension is incomplete. Click Refresh after suspension finishes.")
        if claim is not None:
            pods = self.kubectl("get", "pods", "-l",
                                f"{CLAIM_UID_LABEL}={claim['metadata']['uid']}", "-o", "json")["items"]
        else:
            pods = [
                pod for pod in self.kubectl("get", "pods", "-o", "json")["items"]
                if any(owner.get("kind") == "Sandbox" and owner.get("uid") == sandbox["metadata"]["uid"]
                       for owner in pod["metadata"].get("ownerReferences", []))
            ]
        if pods:
            raise PortalError("Sandbox still has Pods; wait for suspension to remove them before restoring.")
        snapshot = self.snapshot_for(sandbox)
        allowed = self.kubectl(
            "create", "-f", "-", "-o", "json", "--validate=false",
            "--as=system:serviceaccount:agent-sandbox-system:agent-sandbox-controller",
            document={
                "apiVersion": "authorization.k8s.io/v1",
                "kind": "SelfSubjectAccessReview",
                "spec": {"resourceAttributes": {
                    "namespace": self.namespace, "verb": "restore",
                    "group": "podsnapshot.aks.azure.com",
                    "resource": "podsnapshots", "name": snapshot,
                }},
            },
        )
        if allowed.get("status", {}).get("allowed") is not True:
            raise PortalError("Agent Sandbox controller lacks restore permission for this snapshot.")
        update = {
            "metadata": {"resourceVersion": sandbox["metadata"]["resourceVersion"]},
            "spec": {
                "operatingMode": "Running",
                "podTemplate": {"metadata": {
                    "labels": {RESTORE_LABEL: "true"},
                    "annotations": {RESTORE_FROM: snapshot},
                }},
            },
        }
        LOGGER.info("Restoring Sandbox %s from snapshot %s in %s", name, snapshot, self.namespace)
        self.kubectl("patch", "sandbox", name, "--type=merge", "--patch", json.dumps(update), "-o", "json")
        return snapshot

    def open_sandbox(self, name):
        sandbox, _ = self.selected(name)
        state = {
            "name": name,
            "mode": sandbox.get("spec", {}).get("operatingMode", "Running"),
            "status": sandbox_status(sandbox),
            "ready": sandbox_status(sandbox) == "Ready",
            "snapshot": self.mapped_snapshot(sandbox),
        }
        if not state["ready"]:
            return state
        _, gateway = self.gateway_address()
        root = gateway + "/" + sandbox["metadata"]["name"]
        status, detail = self.health(root)
        if status != 200:
            raise PortalError(f"/health check failed: {detail or f'HTTP {status}'}")
        return {**state, "url": root + "/"}

    @staticmethod
    def pods_owned_by(pods, sandbox):
        return [pod for pod in pods if any(
            owner.get("kind") == "Sandbox" and owner.get("uid") == sandbox["metadata"]["uid"]
            for owner in pod["metadata"].get("ownerReferences", [])
        )]

    def wait_for_no_pods(self, sandbox):
        deadline = time.monotonic() + 600
        while self.pods_owned_by(self.kubectl("get", "pods", "-o", "json")["items"], sandbox):
            if time.monotonic() >= deadline:
                raise PortalError("Sandbox Pods remain after shutdown; inspect resources before retrying.")
            time.sleep(2)

    def delete_resource(self, resource):
        name = resource["metadata"]["name"]
        kind = resource["kind"].lower()
        current = self.kubectl("get", kind, name, "--ignore-not-found", "-o", "json")
        if not current:
            return
        if current["metadata"]["uid"] != resource["metadata"]["uid"]:
            raise PortalError(f"{kind}/{name} was replaced; refusing to delete a different resource.")
        if current["metadata"]["resourceVersion"] != resource["metadata"]["resourceVersion"]:
            raise PortalError(f"{kind}/{name} changed after preflight; inspect it before retrying.")
        api = resource["apiVersion"]
        prefix = f"/apis/{api}" if "/" in api else f"/api/{api}"
        plural = {"Sandbox": "sandboxes", "SandboxClaim": "sandboxclaims", "Pod": "pods",
                  "Service": "services", "HTTPRoute": "httproutes"}[resource["kind"]]
        self.kubectl("delete", "--raw", f"{prefix}/namespaces/{self.namespace}/{plural}/{name}",
                     "-f", "-", document={
                         "apiVersion": "v1", "kind": "DeleteOptions",
                         "propagationPolicy": "Foreground",
                         "preconditions": {"uid": current["metadata"]["uid"],
                                           "resourceVersion": current["metadata"]["resourceVersion"]},
                     })
        deadline = time.monotonic() + 600
        while self.kubectl("get", kind, name, "--ignore-not-found", "-o", "json"):
            if time.monotonic() >= deadline:
                raise PortalError(f"Timed out deleting {kind}/{name}; inspect resources before retrying.")
            time.sleep(2)

    def authorize_restore(self, name, snapshot):
        role_name = f"portal-restore-{name}"
        resources = [{
                "apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role",
                "metadata": {"name": role_name, "namespace": self.namespace},
                "rules": [{"apiGroups": ["podsnapshot.aks.azure.com"], "resources": ["podsnapshots"],
                           "resourceNames": [snapshot], "verbs": ["restore"]}],
            }, {
                "apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding",
                "metadata": {"name": role_name, "namespace": self.namespace},
                "subjects": [{"kind": "ServiceAccount", "name": "agent-sandbox-controller",
                              "namespace": "agent-sandbox-system"}],
                "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": role_name},
            }]
        for resource in resources:
            self.kubectl("apply", "-f", "-", "-o", "json", document=resource)
        allowed = self.kubectl(
            "create", "-f", "-", "-o", "json", "--validate=false",
            "--as=system:serviceaccount:agent-sandbox-system:agent-sandbox-controller",
            document={
                "apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview",
                "spec": {"resourceAttributes": {
                    "namespace": self.namespace, "verb": "restore",
                    "group": "podsnapshot.aks.azure.com", "resource": "podsnapshots", "name": snapshot,
                }},
            },
        )
        if allowed.get("status", {}).get("allowed") is not True:
            raise PortalError("Agent Sandbox controller lacks restore permission for this snapshot.")

    def restore_sandbox(self, sandbox, claim, snapshot):
        name = sandbox["metadata"]["name"]
        captured = self.kubectl("get", "podsnapshot", snapshot, "-o", "json")
        if not ready(captured) or captured["metadata"].get("deletionTimestamp"):
            raise PortalError("The mapped snapshot is not Ready; refusing to cold-start instead.")
        manifest = Path(__file__).resolve().parent / "manifests" / "session.yaml"
        templates = list(yaml.safe_load_all(manifest.read_text(encoding="utf-8")))
        restored = copy.deepcopy(next(item for item in templates if item["kind"] == "Sandbox"))
        restored["metadata"] = {
            "name": name, "namespace": self.namespace, "labels": {RESTORED_POOL_LABEL: self.pool},
        }
        # Preserve the rendered session's actual image, identity, probes and sizing.
        restored["spec"]["podTemplate"] = copy.deepcopy(sandbox["spec"]["podTemplate"])
        pod_spec = restored["spec"]["podTemplate"]["spec"]
        if (pod_spec.get("enableServiceLinks") is not False
                or pod_spec.get("runtimeClassName") != "kata-vm-isolation-v2"
                or any(not re.fullmatch(r".+@sha256:[a-f0-9]{64}", container["image"])
                       for container in pod_spec["containers"])):
            raise PortalError("Restore requires the source session's digest-pinned image and Kata v2 settings.")
        restored["spec"]["operatingMode"] = "Running"
        metadata = restored["spec"]["podTemplate"].setdefault("metadata", {})
        metadata.setdefault("labels", {})[RESTORE_LABEL] = "true"
        metadata["labels"][RESTORED_POD_LABEL] = name
        metadata.setdefault("annotations", {})[RESTORE_FROM] = snapshot
        template = route_template()
        template["spec"]["parentRefs"][0]["name"] = self.gateway
        self.kubectl("get", "gateway", self.gateway, "-o", "json")
        owners = {sandbox["metadata"]["uid"]}
        if claim is not None:
            owners.add(claim["metadata"]["uid"])
        related = []
        for kind in ("services", "httproutes"):
            for resource in self.kubectl("get", kind, "-o", "json")["items"]:
                if any(owner.get("uid") in owners for owner in resource["metadata"].get("ownerReferences", [])):
                    related.append(resource)
                elif resource["metadata"]["name"] == name:
                    raise PortalError(f"{kind}/{name} is not owned by this Sandbox/Claim; refusing to replace it.")
        self.authorize_restore(name, snapshot)
        LOGGER.warning("Replacing Sandbox %s and Claim %s using snapshot %s", name,
                       None if claim is None else claim["metadata"]["name"], snapshot)
        if claim is not None:
            self.delete_resource(claim)
        self.delete_resource(sandbox)
        self.wait_for_no_pods(sandbox)
        for resource in related:
            self.delete_resource(resource)
        replacement = self.kubectl("create", "-f", "-", "-o", "json", document=restored)
        record_snapshot(self.snapshot_mapping_path, self.context, replacement, snapshot)
        self.kubectl("wait", "--for=condition=Ready", f"sandbox/{name}", "--timeout=10m",
                     "-o", "json", timeout=615)
        pods = self.pods_owned_by(self.kubectl("get", "pods", "-o", "json")["items"], replacement)
        if len(pods) != 1 or pods[0]["metadata"].get("deletionTimestamp"):
            raise PortalError("Expected one restored Pod; inspect the Sandbox before retrying.")
        pod = pods[0]
        self.kubectl("patch", "pod", pod["metadata"]["name"], "--type=merge", "--patch", json.dumps({
            "metadata": {"resourceVersion": pod["metadata"]["resourceVersion"],
                         "labels": {RESTORED_POD_LABEL: name}},
        }), "-o", "json")
        self.kubectl("wait", "--for=condition=Ready", f"pod/{pod['metadata']['name']}", "--timeout=10m",
                     "-o", "json", timeout=615)
        service = sandbox_service(name, self.namespace, replacement, {RESTORED_POOL_LABEL: self.pool},
                                  {RESTORED_POD_LABEL: name})
        self.kubectl("create", "-f", "-", "-o", "json", document=service)
        self.kubectl("create", "-f", "-", "-o", "json", document=sandbox_route(service, template))
        return self.kubectl("get", "sandbox", name, "-o", "json"), None

    def restore_named_sandbox(self, name):
        if not isinstance(name, str) or NAME.fullmatch(name) is None:
            raise PortalError("Invalid Sandbox name.")
        if not self.wake_lock.acquire(blocking=False):
            raise PortalError("Another Sandbox wake is in progress; wait before retrying.")
        try:
            sandbox = self.kubectl("get", "sandbox", name, "-o", "json")
            metadata = sandbox["metadata"]
            if (metadata["name"] != name or metadata["namespace"] != self.namespace
                    or metadata.get("deletionTimestamp")):
                raise PortalError("Sandbox identity does not match or it is being deleted.")
            snapshot = self.mapped_snapshot(sandbox)
            if not snapshot:
                raise PortalError("No snapshot mapping matches this context, namespace, Sandbox name and UID.")
            owners = [owner for owner in metadata.get("ownerReferences", [])
                      if owner.get("kind") == "SandboxClaim"]
            if len(owners) > 1:
                raise PortalError("Sandbox has multiple Claim owners; refusing restore.")
            claim = None
            if owners:
                claim = self.kubectl("get", "sandboxclaim", owners[0]["name"], "-o", "json")
                if (not self.owned_by_claim(sandbox, claim) or claim["metadata"].get("deletionTimestamp")
                        or claim.get("spec", {}).get("warmPoolRef", {}).get("name") != self.pool
                        or claim.get("status", {}).get("sandbox", {}).get("name") != name):
                    raise PortalError("Sandbox Claim ownership changed; refusing restore.")
            replacement, _ = self.restore_sandbox(sandbox, claim, snapshot)
            return {"sandbox": name, "sandbox_uid": replacement["metadata"]["uid"], "snapshot": snapshot}
        finally:
            self.wake_lock.release()

    def wake_sandbox(self, name, uid):
        if not self.wake_lock.acquire(blocking=False):
            raise PortalError("Another Sandbox wake is in progress; wait before retrying.")
        try:
            cached, claim = self.selected(name)
            sandbox = self.kubectl("get", "sandbox", name, "-o", "json")
            if uid != cached["metadata"]["uid"] or uid != sandbox["metadata"]["uid"]:
                raise PortalError("Sandbox identity changed; refresh the lists before waking it.")
            if sandbox["metadata"].get("deletionTimestamp"):
                raise PortalError("Sandbox is being deleted; cannot wake it.")
            if sandbox["metadata"].get("ownerReferences", []) != cached["metadata"].get("ownerReferences", []):
                raise PortalError("Sandbox ownership changed; refresh the lists before waking it.")
            claim_name = None if claim is None else claim["metadata"]["name"]
            if claim_name is None:
                claim_name = next((owner["name"] for owner in sandbox["metadata"].get("ownerReferences", [])
                                   if owner.get("kind") == "SandboxClaim"), None)
            if claim_name is not None:
                claim = self.kubectl("get", "sandboxclaim", claim_name, "-o", "json")
                if (not self.owned_by_claim(sandbox, claim) or claim["metadata"].get("deletionTimestamp")
                        or claim.get("spec", {}).get("warmPoolRef", {}).get("name") != self.pool
                        or claim.get("status", {}).get("sandbox", {}).get("name") != name):
                    raise PortalError("Sandbox Claim ownership changed; refresh the lists before waking it.")
            snapshot = self.mapped_snapshot(sandbox)
            action = None
            if sandbox_status(sandbox) != "Ready":
                if (sandbox_status(sandbox) not in ("Stopped", "Suspended")
                        and sandbox.get("spec", {}).get("operatingMode") not in ("Suspended", "Stopped")):
                    raise PortalError("Only stopped or suspended Sandboxes can be auto-woken.")
                if snapshot:
                    sandbox, claim = self.restore_sandbox(sandbox, claim, snapshot)
                    action = "restored"
                else:
                    metadata = sandbox["spec"]["podTemplate"].get("metadata", {})
                    if metadata.get("labels", {}).get(RESTORE_LABEL) == "true" or RESTORE_FROM in metadata.get("annotations", {}):
                        raise PortalError("A restore Sandbox has no mapping; repair its mapping before waking it.")
                    LOGGER.warning("Cold-starting Sandbox %s without a mapped snapshot; in-memory state is lost", name)
                    if sandbox.get("spec", {}).get("operatingMode") != "Suspended":
                        sandbox = self.kubectl("patch", "sandbox", name, "--type=merge", "--patch", json.dumps({
                            "metadata": {"resourceVersion": sandbox["metadata"]["resourceVersion"]},
                            "spec": {"operatingMode": "Suspended"},
                        }), "-o", "json")
                    self.wait_for_no_pods(sandbox)
                    sandbox = self.kubectl("get", "sandbox", name, "-o", "json")
                    if sandbox["metadata"]["uid"] != uid or sandbox["spec"].get("operatingMode") != "Suspended":
                        raise PortalError("Sandbox changed during shutdown; inspect it before retrying.")
                    sandbox = self.kubectl("patch", "sandbox", name, "--type=merge", "--patch", json.dumps({
                        "metadata": {"resourceVersion": sandbox["metadata"]["resourceVersion"]},
                        "spec": {"operatingMode": "Running"},
                    }), "-o", "json")
                    sandbox = self.kubectl("wait", "--for=condition=Ready", f"sandbox/{name}", "--timeout=10m",
                                           "-o", "json", timeout=615)
                    action = "cold-start"
            ip, selections = self.cached_state
            if claim is not None or sandbox["metadata"].get("labels", {}).get(RESTORED_POOL_LABEL) == self.pool:
                self.cached_state = (ip, {**selections, name: (sandbox, claim)})
                self.cached_warm.pop(name, None)
            else:
                self.cached_warm[name] = sandbox
            return {**self.open_sandbox(name), "wake_action": action}
        finally:
            self.wake_lock.release()


class PortalHandler(BaseHTTPRequestHandler):
    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_body(status, body, "application/json; charset=utf-8")

    def send_body(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def authorized(self, api=False):
        hosts = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
        if self.headers.get("Host") not in hosts:
            self.send_json(403, {"error": "Invalid local host."})
            return False
        if api and not hmac.compare_digest(self.headers.get("X-Portal-Token", ""), self.server.token):
            self.send_json(403, {"error": "Missing portal session token."})
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in {f"http://{host}" for host in hosts}:
            self.send_json(403, {"error": "Cross-origin requests are not permitted."})
            return False
        return True

    def do_GET(self):
        if not self.authorized(api=self.path.startswith("/api/")):
            return
        try:
            if self.path == "/":
                html = Path(__file__).with_suffix(".html").read_text(encoding="utf-8")
                self.send_body(200, html.replace("__PORTAL_TOKEN__", self.server.token).encode("utf-8"),
                               "text/html; charset=utf-8")
            elif self.path == "/api/info":
                self.send_json(200, self.server.portal.info())
            elif self.path == "/api/claims":
                self.send_json(200, self.server.portal.claimed_state())
            elif self.path == "/api/warm":
                self.send_json(200, self.server.portal.warm_state())
            elif self.path == "/api/snapshots":
                self.send_json(200, self.server.portal.snapshot_state())
            else:
                self.send_json(404, {"error": "Not found."})
        except (PortalError, OSError, ValueError, KeyError) as error:
            LOGGER.exception("Portal request failed")
            self.send_json(502, {"error": str(error)})

    def do_POST(self):
        if not self.authorized(api=True):
            return
        if self.path not in ("/api/open", "/api/wake"):
            self.send_json(404, {"error": "Not found."})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 4096:
                raise ValueError("Request body must contain at most 4096 bytes.")
            payload = json.loads(self.rfile.read(size))
            if not isinstance(payload, dict) or not isinstance(payload.get("name"), str):
                raise ValueError("Expected a Sandbox name.")
            if "auto_wake" in payload:
                raise ValueError("Use /api/wake with the selected Sandbox UID instead of auto_wake.")
            if self.path == "/api/wake" and (not isinstance(payload.get("uid"), str) or not payload["uid"]):
                raise ValueError("Expected the selected Sandbox UID.")
        except (ValueError, TypeError) as error:
            self.send_json(400, {"error": str(error)})
            return
        try:
            data = (self.server.portal.wake_sandbox(payload["name"], payload["uid"])
                    if self.path == "/api/wake" else self.server.portal.open_sandbox(payload["name"]))
            self.send_json(200, data)
        except (PortalError, OSError, ValueError, KeyError) as error:
            LOGGER.exception("Sandbox access failed")
            self.send_json(502, {"error": str(error)})


class PortalServer(ThreadingHTTPServer):
    def __init__(self, portal: SandboxPortal, port: int):
        self.portal = portal
        self.token = secrets.token_hex(32)
        super().__init__(("127.0.0.1", port), PortalHandler)


def create_server(portal, port):
    return PortalServer(portal, port)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", default="agent-lab")
    parser.add_argument("--context", help="kubectl context; defaults to the current context at startup")
    parser.add_argument("--gateway", default="sandbox-gateway")
    parser.add_argument("--pool", default="agent-pool")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--restore", metavar="SANDBOX", help="Restore a mapped Sandbox and exit; do not start HTTP")
    args = parser.parse_args()
    if any(NAME.fullmatch(value) is None for value in (args.namespace, args.gateway, args.pool)):
        parser.error("Namespace, Gateway and pool must be valid DNS labels.")
    if args.namespace == "default" or args.namespace.startswith("kube-"):
        parser.error("Use a dedicated non-system namespace.")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not args.context:
        args.context = subprocess.run(
            ["kubectl", "config", "current-context"], text=True, capture_output=True, check=True,
        ).stdout.strip()
    if not args.context:
        parser.error("Select a kubectl context first.")
    if args.restore is not None:
        try:
            result = SandboxPortal(args.namespace, args.context, args.gateway, args.pool).restore_named_sandbox(
                args.restore,
            )
        except (PortalError, OSError, ValueError, KeyError) as error:
            parser.exit(1, f"ERROR: Restore failed: {error}\nInspect resources before retrying; no cold-start fallback.\n")
        print(f"Restored Sandbox: {result['sandbox']}; UID: {result['sandbox_uid']}; snapshot: {result['snapshot']}")
        print("Sandbox and Pod are Ready; Service and HTTPRoute created. "
              "In-memory state equality was not verified; validate application state and service access separately.")
        return
    server = create_server(SandboxPortal(args.namespace, args.context, args.gateway, args.pool), args.port)
    print(f"Sandbox portal: http://127.0.0.1:{server.server_port}/", flush=True)
    print(f"Context: {args.context}; namespace: {args.namespace}. Access requires cached Ready status "
          "and HTTP 200 from /health.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
