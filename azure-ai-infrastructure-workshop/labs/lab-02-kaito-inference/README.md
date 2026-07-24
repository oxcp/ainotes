# Lab 02: KAITO inference

## Objectives

- Confirm the AI toolchain operator managed add-on is enabled.
- Deploy a version-validated KAITO Workspace.
- Observe scheduling and readiness.
- Call the model using curl and the OpenAI Python client.

## Before delivery

The instructor must replace `<GPU_VM_SIZE>` and `<VALIDATED_KAITO_PRESET>` with values validated against the deployed KAITO version and available quota.

## Deploy

```bash
kubectl apply -f manifests/workspace-preset.yaml
kubectl get workspace -w
kubectl describe workspace workshop-model
kubectl get pods -o wide
kubectl get events --sort-by=.lastTimestamp
```

## Access

Identify the generated service, then use local port forwarding:

```bash
kubectl get service
kubectl port-forward service/<SERVICE_NAME> 8000:<SERVICE_PORT>
```

In another terminal:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r python/requirements.txt
export MODEL_BASE_URL=http://127.0.0.1:8000/v1
export MODEL_NAME=<SERVED_MODEL_NAME>
python python/chat.py
```

## Success criteria

Workspace is ready, a GPU-backed model pod is running, and the Python client receives a response.

## Cleanup

```bash
kubectl delete -f manifests/workspace-preset.yaml
```
