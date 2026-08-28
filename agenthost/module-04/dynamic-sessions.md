# Optional Learning Track: ACA Dynamic Sessions

[Back to Module 4](./README.md)

> [!IMPORTANT]
> **This learning track is still under development and will be updated soon.**

This section is optional. It is intended for learners who complete the main
Sandbox path early and want to compare a different Azure Container Apps execution
model. It is not required to complete the workshop.

> [!IMPORTANT]
> **Dynamic Sessions is not an ideal host for running an agent.**
> It is purpose-built to provide **temporary, strongly isolated execution
> environments**, for example, to safely run AI-generated or otherwise untrusted
> code. Each session is **ephemeral**: it is allocated on demand, runs a short-lived
> task, and is **destroyed after use with no state retained**. A long-running agent
> typically requires a stable, addressable, stateful runtime, which is what the
> **Sandbox** workshop path provides. Treat Dynamic Sessions as a **tool the agent
> calls** to execute code safely, not as the place where the agent itself runs.
>
> See the official comparison:
> [Sandboxes vs. Dynamic Sessions](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview#sandboxes-vs-dynamic-sessions).

Dynamic Sessions use prewarmed **session pools** for fast, ephemeral, high-concurrency
execution. They are well suited to short-lived, disposable tasks such as executing
AI-generated code, tool calls, or code interpreters. In an agent architecture, the
agent runs elsewhere, for example on the Sandbox path, and **offloads risky code
execution** to a Dynamic Session. The session is discarded after the task completes.

## Files

- `dynamic-session-deploy.sh`
- `dynamic-session-invoke.sh` (minimal invocation example)

## What It Deploys

- An ACA environment for session pool hosting, if one does not already exist
- A custom container session pool created with `az containerapp sessionpool create`
- A management endpoint for per-session invocation using `identifier`-based routing

## Deploy

**Run:**

```bash
cd agenthost/module-04
./dynamic-session-deploy.sh
```

## Minimal Invoke Examples

**Run:**

```bash
cd agenthost/module-04

# Default: call /health with identifier=test-session
./dynamic-session-invoke.sh

# Use a custom identifier
./dynamic-session-invoke.sh user-42

# Use a custom endpoint and JSON body
ENDPOINT_PATH=/api/projects/demo/openai/v1/responses \
METHOD=POST \
BODY='{"messages":[{"role":"user","content":"hello"}]}' \
./dynamic-session-invoke.sh user-42
```

## Validate

**Run:**

```bash
az containerapp sessionpool list -g rg-agenthost-workshop -o table
```

## When to Explore This

Explore Dynamic Sessions to understand the **secure code-execution** model that an
agent can call as a tool, rather than as a way to host the agent itself:

- You want to safely run AI-generated or untrusted code in a disposable environment
- You need strong isolation for a single short task, followed by automatic teardown
- You want fast per-request or per-session allocation from a prewarmed pool
- You explicitly do **not** need to preserve state between runs

> If you need a persistent, addressable, stateful environment in which to run the
> agent, use the **Sandbox** workshop path instead.

---

[Back to Module 4](./README.md)
