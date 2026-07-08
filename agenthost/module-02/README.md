# Module 2 — Solution A: Foundry Hosted Agent (azd)

## Overview

This module extends the resource group created by module-01 with a Microsoft Foundry resource, a project, a model deployment, Defender for AI, and RAI policies. The hosted agent itself is deployed with `azd`, following the official Microsoft Foundry hosted-agent sample:

https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework/responses/01-basic

## Learning Objectives

- Create a Foundry resource named `foundry-agenthost-<deploymentSuffix>`
- Create the project `maf-agent-basic-resp`
- Deploy `gpt-5.4-mini` with capacity 50
- Enable Defender for AI and apply `Microsoft.Default` / `Microsoft.DefaultV2`
- Use `azd` to initialize, provision, run locally, deploy, and invoke the hosted agent
- Route LLM calls through the APIM instance created in module-01

## Prerequisites

- Module 1 already deployed
- The module-01 resource group still contains the `deploymentSuffix` tag
- Azure CLI, Azure Developer CLI, and Docker Desktop installed
- The Microsoft Foundry extension for azd installed: `azd ext install microsoft.foundry`
- The hosted-agent sample available as the source-of-truth for the application code and `azure.yaml`

## Step 1 — Deploy the Foundry infrastructure

Use the module-02 Bicep file to create the Foundry resource and project in the resource group created by module-01.

```bash
az deployment group create \
  --resource-group rg-agenthost-workshop \
  --template-file hostedagent.bicep \
  --parameters location=eastus2
```

If you need to override names, pass:

```bash
az deployment group create \
  --resource-group rg-agenthost-workshop \
  --template-file hostedagent.bicep \
  --parameters \
    location=eastus2 \
    foundryResourceName=foundry-agenthost \
    projectName=maf-agent-basic-resp \
    apimName=apim-agenthost
```

## Step 2 — Initialize the hosted agent from the sample

Create a new working folder for the agent code, then initialize it from the Microsoft Foundry sample manifest.

```bash
mkdir maf-agent-basic-resp
cd maf-agent-basic-resp
azd auth login
azd ext install microsoft.foundry
azd ai agent init -m ../module-02/azure.yaml
```

When prompted, select the Foundry project that matches `maf-agent-basic-resp` and keep the agent name aligned with the sample. If you prefer the upstream source, the same manifest is published in the Microsoft Foundry sample repository.

## Step 3 — Provision and run locally

Provision the model deployment and agent scaffolding, then configure the local environment before running.

```bash
azd provision
```

The agent app under `src/agent-framework-agent-basic-responses/` reads two variables from a local `.env` when running outside Foundry. Populate them from the `hostedagent.bicep` outputs (Step 1):

```bash
cd src/agent-framework-agent-basic-responses
cp .env.example .env
# FOUNDRY_PROJECT_ENDPOINT       = hostedagent.bicep output `foundryProjectEndpoint`
# AZURE_AI_MODEL_DEPLOYMENT_NAME = hostedagent.bicep output `modelDeploymentName` (gpt-5.4-mini)
cd -
```

Retrieve the values from the deployment you ran in Step 1:

```bash
az deployment group show \
  --resource-group rg-agenthost-workshop \
  --name hostedagent \
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

## Step 4 — Deploy the hosted agent

```bash
azd deploy
```

Each deployment creates a new hosted-agent version in Foundry. If the sample requires image or model overrides, keep them in the generated `azure.yaml` instead of hardcoding them in the Bicep file.

## Step 5 — Invoke the deployed agent

```bash
azd ai agent invoke "Hi"
```

## Step 6 — APIM as the AI gateway for Foundry

`hostedagent.bicep` configures the module-01 API Management instance as an AI gateway in front of the Foundry resource. It provisions three things:

1. **Backend** `foundry-host-agent` → the Foundry inference endpoint (`foundryAccount.properties.endpoint`), mirroring the module-01 `azure-openai` backend.
2. **RBAC** — the module-01 user-assigned managed identity is granted **Cognitive Services OpenAI User** on the Foundry account. This is mandatory because the Foundry account sets `disableLocalAuth: true` (API keys are disabled), so APIM must call Foundry with an Entra ID token.
3. **API** `foundry-ai-gateway` (path `/foundry`) with a `chat-completions` operation and an API-scope policy that routes to the `foundry-host-agent` backend and attaches a managed-identity token via `authentication-managed-identity` (resource `https://cognitiveservices.azure.com`).

> Deploying the role assignment requires the deployer to have **Owner** or **User Access Administrator** on the resource group (Contributor alone cannot create role assignments).

Call the model through the gateway (Entra ID auth to APIM handled per your caller policy):

```bash
# Gateway URL comes from the deployment output `apimFoundryGatewayUrl`
curl -X POST "https://apim-agenthost-<suffix>.azure-api.net/foundry/deployments/gpt-5.4-mini/chat/completions?api-version=2024-02-01" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello through the APIM AI gateway"}],"max_tokens":64}'
```

Retrieve the gateway URL and backend name from the Step 1 deployment:

```bash
az deployment group show \
  --resource-group rg-agenthost-workshop \
  --name hostedagent \
  --query "properties.outputs.{gateway:apimFoundryGatewayUrl.value, backend:apimFoundryBackendName.value}"
```

## Files in This Module

| File | Description |
|---|---|
| `azure.yaml` | Foundry agent manifest used by `azd ai agent init` |
| `src/agent-framework-agent-basic-responses/main.py` | Agent Framework `FoundryChatClient` served with `ResponsesHostServer` |
| `src/agent-framework-agent-basic-responses/requirements.txt` | Python dependencies for the hosted agent |
| `src/agent-framework-agent-basic-responses/.env.example` | Local env template (`FOUNDRY_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME`) |
| `src/agent-framework-agent-basic-responses/Dockerfile` | Container build for the hosted agent runtime |
| `hostedagent.bicep` | Foundry resource, project, model deployment, Defender for AI, RAI policies, and the APIM AI gateway (backend + RBAC + API/policy) |
| `deploy.sh` | Thin wrapper for the Bicep deployment and azd setup steps |
| `agent-definition.json` | Hosted agent runtime settings aligned with the new Foundry resource and APIM backend |
| `apim-policy.xml` | Extended reference policy (validate-jwt, rate-limit, caching) you can merge into the gateway API |

## Next Step

Proceed to [Module 3 — Solution B: ACA Sandbox](../module-03/README.md).
