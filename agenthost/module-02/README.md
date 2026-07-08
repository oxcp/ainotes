# Module 2 — Solution A: Foundry Hosted Agent (azd)

## Overview

The Foundry infrastructure — the `foundry-agenthost-<deploymentSuffix>` account, the `maf-agent-basic-resp` project, the `gpt-5.4-mini` deployment, Defender for AI, the RAI policies, and the APIM AI gateway — is provisioned by **module-01**. This module deploys the hosted agent itself with `azd`, following the official Microsoft Foundry hosted-agent sample:

https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework/responses/01-basic

## Learning Objectives

- Use `azd` to initialize, provision, run locally, deploy, and invoke the hosted agent
- Target the `maf-agent-basic-resp` project and `gpt-5.4-mini` deployment created in module-01
- Route LLM calls through the APIM AI gateway created in module-01

## Prerequisites

- Module 1 already deployed (Foundry account `foundry-agenthost-<deploymentSuffix>`, project `maf-agent-basic-resp`, model `gpt-5.4-mini`)
- The module-01 resource group still contains the `deploymentSuffix` tag
- Azure CLI, Azure Developer CLI, and Docker Desktop installed
- The Microsoft Foundry extension for azd installed: `azd ext install microsoft.foundry`
- The hosted-agent sample available as the source-of-truth for the application code and `azure.yaml`

## Step 1 — Initialize the hosted agent from the sample

Create a new working folder for the agent code, then initialize it from the Microsoft Foundry sample manifest.

```bash
mkdir maf-agent-basic-resp
cd maf-agent-basic-resp
azd auth login
azd ext install microsoft.foundry
azd ai agent init -m ../module-02/azure.yaml
```

When prompted, select the Foundry project that matches `maf-agent-basic-resp` and keep the agent name aligned with the sample. If you prefer the upstream source, the same manifest is published in the Microsoft Foundry sample repository.

## Step 2 — Provision and run locally

Provision the agent scaffolding, then configure the local environment before running.

```bash
azd provision
```

The agent app under `src/agent-framework-agent-basic-responses/` reads two variables from a local `.env` when running outside Foundry. Populate them from the **module-01** deployment outputs:

```bash
cd src/agent-framework-agent-basic-responses
cp .env.example .env
# FOUNDRY_PROJECT_ENDPOINT       = module-01 output `foundryProjectEndpoint`
# AZURE_AI_MODEL_DEPLOYMENT_NAME = module-01 output `modelDeploymentName` (gpt-5.4-mini)
cd -
```

Retrieve the values from the module-01 deployment:

```bash
az deployment sub show \
  --name main \
  --query "properties.outputs.{endpoint:foundryProjectEndpoint.value, model:modelDeploymentName.value}"
```

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

## Step 5 — Call the model through the APIM AI gateway

The APIM AI gateway in front of Foundry is provisioned by **module-01** (backend `foundry-host-agent`, API `foundry-ai-gateway` at path `/foundry`, with managed-identity auth). Retrieve the gateway URL from the module-01 outputs and call it:

```bash
az deployment sub show \
  --name main \
  --query "properties.outputs.{gateway:apimFoundryGatewayUrl.value, backend:apimFoundryBackendName.value}"

curl -X POST "https://apim-agenthost-<suffix>.azure-api.net/foundry/deployments/gpt-5.4-mini/chat/completions?api-version=2024-02-01" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello through the APIM AI gateway"}],"max_tokens":64}'
```

## Files in This Module

| File | Description |
|---|---|
| `azure.yaml` | Foundry agent manifest used by `azd ai agent init` |
| `src/agent-framework-agent-basic-responses/main.py` | Agent Framework `FoundryChatClient` served with `ResponsesHostServer` |
| `src/agent-framework-agent-basic-responses/requirements.txt` | Python dependencies for the hosted agent |
| `src/agent-framework-agent-basic-responses/.env.example` | Local env template (`FOUNDRY_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME`) |
| `src/agent-framework-agent-basic-responses/Dockerfile` | Container build for the hosted agent runtime |
| `agent-definition.json` | Hosted agent runtime settings aligned with the module-01 Foundry resource and APIM backend |

## Next Step

Proceed to [Module 3 — Solution B: ACA Sandbox](../module-03/README.md).
