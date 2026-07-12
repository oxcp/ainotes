# Module 3 — Container Compute Options for Agent Runtime

## Overview

Module-03 now provides two container-runtime choices:

| Solution | Runtime | Primary Use Case | Isolation | State Model |
|---|---|---|---|---|
| **A: ACA Sandboxes** | Azure Container Apps Sandboxes | Untrusted code execution, strong isolation, suspend/resume | gVisor OS-level | Stateful via snapshots |
| **B: ACA Dynamic Sessions** | Azure Container Apps Session Pools | Fast ephemeral execution, prewarmed pools, high concurrency | Session-level isolated containers | Ephemeral session state |

This mapping is intentional:
- **Solution A = Sandbox**
- **Solution B = Dynamic Session**

---

## Prerequisites

1. Module-01 is deployed and `deploymentSN` tag exists on the resource group.
2. Docker is installed and running.
3. Azure CLI is installed.
4. Container Apps extension is installed/upgraded with preview support:

```bash
az extension add --name containerapp --upgrade --allow-preview true -y
```

Additional requirement for Solution A (Sandbox):
- Role assignment: `Container Apps SandboxGroup Data Owner`

---

## Solution A — ACA Sandboxes

### Files

- `sandbox.bicep`
- `sandbox-deploy.sh`
- `deploy.sh` (compatibility wrapper, routes to `sandbox-deploy.sh`)

### What It Deploys

- `Microsoft.App/SandboxGroups` (preview)
- SandboxGroup identity/registry binding
- Optional references to module-01 storage/redis for state workflows

### Deploy

```bash
cd agenthost/module-03
./sandbox-deploy.sh
```

Or use compatibility command:

```bash
./deploy.sh
```

### Characteristics

- Strong isolation for risky workloads
- Lifecycle control (create/suspend/resume/delete)
- Snapshot-based state continuity
- Best when safety and resumability matter more than simple API pooling

---

## Solution B — ACA Dynamic Sessions

### Files

- `dynamic-session-deploy.sh`
- `dynamic-session-invoke.sh` (minimal invocation example)

### What It Deploys

- ACA environment for session pool hosting (if missing)
- Custom container session pool via `az containerapp sessionpool create`
- Management endpoint for per-session invocation (`identifier` based routing)

### Deploy

```bash
cd agenthost/module-03
./dynamic-session-deploy.sh
```

### Minimal Invoke Example

```bash
cd agenthost/module-03

# Default: calls /health with identifier=test-session
./dynamic-session-invoke.sh

# Custom identifier
./dynamic-session-invoke.sh user-42

# Custom endpoint and JSON body
ENDPOINT_PATH=/api/projects/demo/openai/v1/responses \
METHOD=POST \
BODY='{"messages":[{"role":"user","content":"hello"}]}' \
./dynamic-session-invoke.sh user-42
```

### Characteristics

- Prewarmed pool for low-latency allocation
- Built for short-lived/ephemeral session execution
- Horizontal burst for concurrent execution tasks
- Best for rapid, repeated isolated tasks (agent tool execution loops, code runners)

---

## Quick Choice Guide

Use **Solution A (Sandbox)** when you need:
- Full lifecycle control with suspend/resume
- Stronger boundary for untrusted workloads
- State snapshots between runs

Use **Solution B (Dynamic Sessions)** when you need:
- Fast per-request/per-session execution
- High concurrency with pool-based allocation
- Ephemeral and disposable session behavior

---

## Common Validation Commands

### Validate Solution A artifacts

```bash
az resource list -g rg-agenthost-workshop --query "[?contains(type, 'SandboxGroups')].[name,type]" -o table
```

### Validate Solution B artifacts

```bash
az containerapp sessionpool list -g rg-agenthost-workshop -o table
```

---

## Notes

- `aca.bicep` remains in repo as legacy standard ACA reference, but it is not part of the current Solution A/B mapping.
- If you want, this legacy file can be removed in a follow-up cleanup PR.
