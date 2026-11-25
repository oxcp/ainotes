"""Build Sandbox-scoped Services and routes for claims and restored sessions."""
import copy
from pathlib import Path

import yaml


def route_template() -> dict:
    manifest = Path(__file__).resolve().parents[1] / "manifests" / "session.yaml"
    templates = [
        document for document in yaml.safe_load_all(manifest.read_text(encoding="utf-8"))
        if isinstance(document, dict) and document.get("kind") == "HTTPRoute"
    ]
    if len(templates) != 1:
        raise ValueError("Session manifest must define exactly one HTTPRoute template.")
    return templates[0]


def sandbox_service(name: str, namespace: str, owner: dict, labels: dict, selector: dict) -> dict:
    return {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": name, "namespace": namespace,
            "labels": copy.deepcopy(labels),
            "ownerReferences": [{
                "apiVersion": owner["apiVersion"], "kind": owner["kind"],
                "name": owner["metadata"]["name"], "uid": owner["metadata"]["uid"],
                "blockOwnerDeletion": True,
            }],
        },
        "spec": {
            "type": "ClusterIP", "selector": selector,
            "ports": [{"name": "http", "port": 80, "targetPort": 8080}],
        },
    }


def sandbox_route(service: dict, template: dict) -> dict:
    name = service["metadata"]["name"]
    route = copy.deepcopy(template)
    route["metadata"] = copy.deepcopy(service["metadata"])
    rule = copy.deepcopy(template["spec"]["rules"][0])
    rule["matches"] = [{"path": {"type": "PathPrefix", "value": f"/{name}"}}]
    rule["backendRefs"] = [{
        "group": "", "kind": "Service", "name": name, "port": 80, "weight": 1,
    }]
    route["spec"]["rules"] = [rule]
    return route
