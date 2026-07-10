# Module 2 — Solution A: Foundry Hosted Agent (azd)

## Overview

The Foundry infrastructure — the `foundry-agenthost-<deploymentSN>` account, the `maf-agent-prj` project, the `gpt-5.4-mini` deployment, Defender for AI, the RAI policies, and the APIM AI gateway — is provisioned by **module-01**. This module deploys the hosted agent itself with `azd`, following the official Microsoft Foundry hosted-agent sample:

https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework/responses/01-basic

## Learning Objectives

- Use `azd` to initialize, provision, run locally, deploy, and invoke the hosted agent
- Target the `maf-agent-prj` project and `gpt-5.4-mini` deployment created in module-01
- Support **two model-routing modes** and switch between them with a single env var (`MODEL_ROUTING`):
  - `direct` — the agent calls the Foundry project endpoint directly
  - `gateway` — the agent calls the model through the module-01 APIM AI gateway

## Two model-routing modes

The agent's model client is selected at startup by `MODEL_ROUTING` (see [src/maf-agent/main.py](src/maf-agent/main.py)):

| Aspect | `direct` | `gateway` (default) |
|---|---|---|
| Client | `FoundryChatClient` → project endpoint | `OpenAIChatClient` → `<gateway>/responses` |
| Network path | Agent → Foundry | Agent → APIM → Foundry |
| Auth to model | Agent identity holds **Azure AI User** on the Foundry account (module-01 RBAC) | Agent presents an Entra token with `aud = api://agenthost`; the **gateway's** UAMI holds the Foundry RBAC |
| Required env | `FOUNDRY_PROJECT_ENDPOINT` | `APIM_GATEWAY_URL`, `APIM_AUDIENCE` |
| Pros | Fewer hops → lower latency; nothing extra to stand up; simplest RBAC | Central governance: rate-limiting, quotas, logging, caching, key rotation, per-caller JWT validation; hides the Foundry endpoint; one front door for many callers |
| Cons | No central throttling/observability; every caller needs direct Foundry RBAC; endpoint exposed to each client | Extra hop → added latency + APIM cost; requires the `api://agenthost` Entra app to exist and callers to be granted; more moving parts to operate |
| Best for | Simple, low-scale, single-consumer agents | Shared/enterprise gateways, many consumers, policy enforcement |

Both clients speak the **Responses** protocol, so the hosted agent (served by `ResponsesHostServer`) behaves identically to callers regardless of the mode.

## Prerequisites

- Module 1 already deployed (Foundry account `foundry-agenthost-<deploymentSN>`, project `maf-agent-prj`, model `gpt-5.4-mini`)
- The module-01 resource group still contains the `deploymentSN` tag
- Azure CLI, Azure Developer CLI, and Docker Desktop installed
- The Microsoft Foundry extension for azd installed: `azd ext install microsoft.foundry`
- The hosted-agent sample available as the source-of-truth for the application code and `azure.yaml`

## Step 1 — Bind the hosted agent to the module-01 Foundry project

module-01 already created the Foundry account, the `maf-agent-prj` project, and the `gpt-5.4-mini` deployment. To make `azd` **reuse** them instead of provisioning a brand-new account/project, initialize the agent with the existing project's **ARM resource ID** (`--project-id`).

First grab the project ID from the module-01 deployment outputs:

```bash
export SN=<deploymentSN>   # the suffix from module-01

export PROJECT_ID=$(az deployment sub show \
  --name "main-$SN" \
  --query "properties.outputs.foundryProjectId.value" -o tsv)
echo "$PROJECT_ID"
```

Then scaffold the agent bound to that project:

```bash
mkdir maf-agent
cd maf-agent
azd auth login
azd ext install microsoft.foundry
azd ai agent init -m ../module-02/azure.yaml --project-id "$PROJECT_ID"
```

`--project-id` binds `azd` to module-01's existing project (init extracts the subscription and location from the ARM ID), so **no new resource group, Foundry account, or project is created**. Keep the agent name aligned with the sample.

> **Important:** module-02 **does not run `azd provision`** (see Step 2), so `azd` never creates or reconciles the model deployment — it deploys the agent against module-01's existing `gpt-5.4-mini`. Just make sure `AZURE_AI_MODEL_DEPLOYMENT_NAME` resolves to `gpt-5.4-mini`.

## Step 2 — Bind the azd environment (skip provision) and run locally

module-01 already provisioned the Foundry account, project, and `gpt-5.4-mini` deployment, so **do not run `azd provision` in this module**. `azd provision`'s job is to create/reconcile the `ai-project` infrastructure; against a module-01-owned project it creates a *new* account/project/model. Instead, point the azd environment at the existing project so `azd deploy` (Step 3) targets it directly:

```bash
azd env set AZURE_AI_PROJECT_ENDPOINT "$(az deployment sub show --name main-$SN --query 'properties.outputs.foundryProjectEndpoint.value' -o tsv)"
azd env set AZURE_AI_PROJECT_ID       "$PROJECT_ID"
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "gpt-5.4-mini"
azd env get-values
```

> **Why no provision?** Once `AZURE_AI_PROJECT_ENDPOINT` is set, the Foundry azd extension uses the existing project as-is, and `azd deploy` performs a **direct code deploy** (the agent service block has `codeConfiguration:`) straight into it — no infrastructure is provisioned by this module.

The agent app under `src/maf-agent/` supports both model-routing modes; pick one with `MODEL_ROUTING` and fill in the matching variables from the **module-01** deployment outputs:

```bash
cd src/maf-agent
cp .env.example .env
# MODEL_ROUTING                 = "gateway" (default) or "direct"
#
# gateway mode:
#   APIM_GATEWAY_URL            = module-01 output `apimFoundryGatewayUrl` (e.g. https://apim-agenthost-<SN>.azure-api.net/foundry)
#   APIM_AUDIENCE              = module-01 param  `apimAudience` (default api://agenthost)
#
# direct mode:
#   FOUNDRY_PROJECT_ENDPOINT   = module-01 output `foundryProjectEndpoint`
#
# shared:
#   AZURE_AI_MODEL_DEPLOYMENT_NAME = module-01 output `modelDeploymentName` (gpt-5.4-mini)
cd -
```

Retrieve the values from the module-01 deployment:

```bash
az deployment sub show \
  --name "main-$SN" \
  --query "properties.outputs.{gateway:apimFoundryGatewayUrl.value, project:foundryProjectEndpoint.value, model:modelDeploymentName.value}"
```

> **Auth prerequisite (gateway mode only):** the gateway's `validate-jwt` policy requires a caller token with `aud = api://agenthost` (the `apimAudience`). The identity running the agent (your `az login` locally, or the agent's managed identity when hosted) must be able to obtain a token for `api://agenthost/.default` — i.e. an Entra app exposing that App ID URI must exist and grant the caller access. The gateway then re-authenticates to Foundry with its own user-assigned managed identity. In `direct` mode this token is not needed; instead the agent identity must hold the **Azure AI User** role on the Foundry account (granted in module-01).

Run the agent locally:

```bash
azd ai agent run
```

The local host listens on `http://localhost:8088`. In a second terminal, invoke it:

```bash
azd ai agent invoke --local "Hi"
```

## Step 3 — Deploy the hosted agent

```bash
azd deploy
```

Each deployment creates a new hosted-agent version in Foundry. If the sample requires image or model overrides, keep them in the generated `azure.yaml`.

## Step 4 — Invoke the deployed agent

```bash
azd ai agent invoke "Hi"
```

In `gateway` mode the agent's model calls flow through the module-01 APIM AI gateway. Validating the gateway directly (an external `curl` with your own Entra token) is covered in **module-01 Step 3** — no need to repeat it here.

## Files in This Module

| File | Description |
|---|---|
| `azure.yaml` | Foundry agent manifest used by `azd ai agent init` |
| `src/maf-agent/main.py` | Agent, served with `ResponsesHostServer`; `build_client()` selects `FoundryChatClient` (direct) or `OpenAIChatClient` → APIM gateway based on `MODEL_ROUTING` |
| `src/maf-agent/requirements.txt` | Python dependencies for the hosted agent (both `agent-framework-foundry` and `agent-framework-openai`) |
| `src/maf-agent/.env.example` | Local env template (`MODEL_ROUTING`, gateway + direct vars, `AZURE_AI_MODEL_DEPLOYMENT_NAME`) |
| `src/maf-agent/Dockerfile` | Container build for the hosted agent runtime |

## Next Step

Proceed to [Module 3 — Solution B: ACA Sandbox](../module-03/README.md).
