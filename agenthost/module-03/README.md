# Module 3 — Solution B: Container-based Agent Runtime (ACA Sandboxes， 30 min)

## Overview

This module deploys the agent runtime onto **Azure Container Apps Sandboxes** — the
workshop's adopted container-based hosting approach. It provides strong OS-level
isolation (gVisor), lifecycle control (create/suspend/resume/delete), and
snapshot-based state continuity.

> Primary workshop path = **ACA Sandboxes**.
> An optional learning track (**ACA Dynamic Sessions**) is included at the end of
> this module for learners who want to explore an alternative execution model.

---

## Prerequisites

1. Module-01 is deployed and the `deploymentSN` tag exists on the resource group.
2. Docker is installed and running.
3. Azure CLI is installed.
4. Container Apps extension is installed/upgraded with preview support:

```bash
az extension add --name containerapp --upgrade --allow-preview true -y
```

5. Role assignment: `Container Apps SandboxGroup Data Owner`

---

## Workshop Path — ACA Sandboxes

### Files

- `sandbox.bicep`
- `sandbox-deploy.sh`

### What It Deploys

- `Microsoft.App/SandboxGroups` (preview)
- SandboxGroup identity/registry binding
- Optional references to module-01 storage/redis for state workflows

### Deploy

```bash
cd agenthost/module-03
./sandbox-deploy.sh
```

### Characteristics

- Strong isolation for risky/untrusted workloads
- Lifecycle control (create/suspend/resume/delete)
- Snapshot-based state continuity
- Best when safety and resumability matter more than simple API pooling

### Validate

```bash
az resource list -g rg-agenthost-workshop \
  --query "[?contains(type, 'SandboxGroups')].[name,type]" -o table
```

---

## Optional Learning Track — ACA Dynamic Sessions

> This section is **optional**. It is provided for learners who finish the main
> Sandbox path early and want to compare a different Azure Container Apps
> execution model. It is **not required** to complete the workshop.

> [!IMPORTANT]
> **Dynamic Sessions is NOT an ideal host for running an agent.**
> It is purpose-built to provide **temporary, strongly-isolated execution
> environments** — for example, safely running AI-generated or otherwise
> untrusted code. Each session is **ephemeral**: it is allocated on demand,
> runs a short-lived task, and is **destroyed after use with no state
> retained**. A long-running agent typically needs a stable, addressable,
> stateful runtime, which is exactly what the **Sandbox** workshop path
> provides. Treat Dynamic Sessions as a **tool the agent calls** to execute
> code safely — not as the place where the agent itself lives.
>
> See the official comparison:
> [Sandboxes vs. Dynamic Sessions](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview#sandboxes-vs-dynamic-sessions).

Dynamic Sessions use prewarmed **session pools** for fast, ephemeral, high-concurrency
execution — a good fit for short-lived, disposable task runs (e.g. running AI-generated
code, tool execution calls, code interpreters). In an agent architecture, the agent
runs elsewhere (e.g. on the Sandbox path) and **offloads risky code execution** to a
Dynamic Session, then discards the session when done.

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

### Validate

```bash
az containerapp sessionpool list -g rg-agenthost-workshop -o table
```

### When to Explore This

Explore Dynamic Sessions to understand the **secure code-execution** model that an
agent can call as a tool — not as a way to host the agent itself:

- You want to safely run AI-generated or untrusted code in a throwaway environment
- You need strong isolation for a single short task, then automatic teardown
- You want fast per-request/per-session allocation from a prewarmed pool
- You explicitly do **not** need to preserve state between runs

> If you need a persistent, addressable, stateful place to run the agent, use the
> **Sandbox** workshop path instead.

---

## Sandbox vs Dynamic Sessions (Reference)

| Aspect | ACA Sandboxes (workshop path) | ACA Dynamic Sessions (optional) |
|---|---|---|
| Runtime | `Microsoft.App/SandboxGroups` | Session Pools |
| Isolation | gVisor OS-level | Session-level isolated containers |
| State | Stateful via snapshots | Ephemeral — destroyed after use, no state retained |
| Lifecycle | create/suspend/resume/delete | pool-managed, cooldown-based auto-teardown |
| Primary purpose | Hosting an isolated, resumable agent runtime | Temporary secure execution of untrusted / AI-generated code |
| Ideal for hosting an agent? | Yes | No — use it as a tool the agent calls |
| Best for | Isolation + resumability | Fast ephemeral, disposable code execution |

---

## Notes

- `container-app.yaml` is a legacy standard ACA YAML manifest and is not used by the current scripts.
- `lifecycle-hook.sh` is packaged into the image by module-03 Dockerfile, and is explicitly invoked in module-04 via Kubernetes preStop hook.
