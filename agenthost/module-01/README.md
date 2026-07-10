# Module 1 — Core Infrastructure Setup (30 min)

## Overview

Provision the shared Azure infrastructure used by all three agent hosting solutions:

- Resource Group
- Azure Managed Redis
- Azure Blob Storage
- Azure API Management
- Azure Key Vault
- Azure Container Registry
- Entra ID App Registration
- User-Assigned Managed Identity
- Microsoft Foundry (AIServices) account

The Foundry account ships with:

- A project
- A `gpt-5.4-mini` model deployment
- Defender for AI
- Two RAI content-safety policies
- The APIM AI gateway that fronts its inference endpoint
- An APIM Basic v2 instance that is eligible for Foundry AI Gateway association

## Learning Objectives

- Deploy shared Azure infrastructure using Bicep IaC
- Configure APIM with a `validate-jwt` policy and Azure OpenAI backend
- Register an Entra ID application and create a User-Assigned Managed Identity
- Create a Foundry resource named `foundry-agenthost-<deploymentSN>` with the project `maf-agent-prj`
- Deploy `gpt-5.4-mini` (capacity 50) and enable Defender for AI
- Apply the `Microsoft.Default` and `Microsoft.DefaultV2` RAI policies
- Expose Foundry inference through APIM as an AI gateway (backend + RBAC + API/policy)

---

## Prerequisites

- Azure subscription with **Contributor** access
- Azure CLI installed and authenticated (`az login`)

---

## Step 1 — Set Environment Variables

```bash
export RESOURCE_GROUP="rg-agenthost-workshop"
export LOCATION="eastus2"
```

---

## Step 2 — Deploy Infrastructure via Bicep

```bash
SN=$(openssl rand -hex 3); echo $SN

az deployment sub create \
  --name "main-$SN" \
  --location "$LOCATION" \
  --template-file main.bicep \
  --parameters \
      resourceGroupName="$RESOURCE_GROUP" \
      location="$LOCATION" \
      deploymentSN="$SN"
```

Or run the automated script (provisions the core resources **and** the full Foundry stack via `az` / `az rest`):

```bash
chmod +x setup.sh
./setup.sh
```

> **RBAC note:** the Foundry account sets `disableLocalAuth: true`, so APIM must call it with an Entra ID token from the user-assigned managed identity. The deployment therefore grants the UAMI the **Cognitive Services OpenAI User** role on the Foundry account. Creating that role assignment requires the deployer to have **Owner** or **User Access Administrator** on the resource group (Contributor alone cannot create role assignments).

---

## Step 3 — Foundry AI gateway (provisioned with the core deployment)

`core.bicep` provisions the Foundry stack and wires the module-01 API Management instance as its AI gateway:

1. **Foundry account** `foundry-agenthost-<deploymentSN>` (kind `AIServices`, `disableLocalAuth: true`) with the project `maf-agent-prj`, the `gpt-5.4-mini` deployment (GlobalStandard, capacity 50), and Defender for AI.
2. **APIM** `apim-agenthost-<deploymentSN>` is created on the **Basic v2** tier so it is eligible for Foundry's native AI Gateway feature.
3. **Backend** `foundry-backend` → the Foundry Responses endpoint (`${foundryAccount.properties.endpoint}openai/v1`).
4. **RBAC** — the module-01 UAMI is granted **Cognitive Services OpenAI User** and **Azure AI User** on the Foundry account.
5. **API** `foundry-ai-gateway` (path `/foundry`) with `responses` (`POST /responses`) and `get-response` (`GET /responses/{response-id}`) operations, plus an API-scope policy that validates the caller's Entra ID token (`validate-jwt`) and then forwards to the backend with a managed-identity token via `authentication-managed-identity` (resource `https://ai.azure.com`).

To make this APIM instance appear in **Microsoft Foundry portal → Operate → Admin console → AI Gateway**, you still need one manual portal step after deployment:

1. Open **AI Gateway**.
2. Select **Add AI Gateway**.
3. Choose **Use existing**.
4. Select the deployed `apim-agenthost-<deploymentSN>` instance.
5. Open the gateway entry and select **Add project to gateway** for `maf-agent-prj`.

Call the model through the gateway (the gateway URL is the `apimFoundryGatewayUrl` output). The caller sends its own Entra ID token; APIM validates it and forwards to Foundry with its managed identity:

```bash
curl -X POST "https://apim-agenthost-<suffix>.azure-api.net/foundry/responses" \
  -H "Authorization: Bearer <caller Entra ID token, aud=api://agenthost>" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.4-mini","input":"Hello through the APIM AI gateway"}'
```

Retrieve the key outputs after deployment:

```bash
az deployment sub show \
  --name main \
  --query "properties.outputs.{endpoint:foundryProjectEndpoint.value, model:modelDeploymentName.value, gateway:apimFoundryGatewayUrl.value, backend:apimFoundryBackendName.value}"
```

---

## Files in This Module

| File | Description |
|---|---|
| `setup.sh` | Automated bash script for full infrastructure setup (core resources + Foundry stack via `az` / `az rest`) |
| `main.bicep` | Bicep subscription-scoped entry point (creates Resource Group, calls core.bicep) |
| `core.bicep` | Bicep IaC template for all shared Azure resources (Redis, Storage, APIM Basic v2, Key Vault, ACR, UAMI) **and** the Foundry stack (account, project, `gpt-5.4-mini`, Defender for AI, APIM AI gateway) |

---

## Outputs

| Output | Description |
|---|---|
| `redisHostName`, `storageAccountName`, `apimServiceUrl`, `identityClientId`, `keyVaultName`, `keyVaultUri`, `acrName`, `acrLoginServer` | Core shared-resource coordinates |
| `foundryResourceName` | Foundry account name (`foundry-agenthost-<suffix>`) |
| `foundryProjectName` / `foundryProjectId` / `foundryProjectEndpoint` | Foundry project identifiers (project endpoint consumed by module-02) |
| `modelDeploymentName` | Deployed model name (`gpt-5.4-mini`) |
| `apimFoundryBackendName` | APIM backend name (`foundry-backend`) |
| `apimFoundryGatewayUrl` | APIM AI gateway URL for Foundry inference |

---

## Next Step

Proceed to [Module 2 — Solution A: Foundry Hosted Agent](../module-02/README.md) to deploy the hosted agent with `azd` against the Foundry project provisioned here.
