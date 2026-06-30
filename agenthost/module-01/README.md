# Module 1 — Core Infrastructure Setup (20 min)

## Overview

Provision the shared Azure infrastructure used by all three agent hosting solutions: Resource Group, Azure Managed Redis, Azure Blob Storage, Azure API Management, Entra ID App Registration, and User-Assigned Managed Identity.

## Learning Objectives

- Deploy shared Azure infrastructure using Bicep IaC
- Configure APIM with a `validate-jwt` policy and Azure OpenAI backend
- Register an Entra ID application and create a User-Assigned Managed Identity

## Schedule

| Time | Activity | Commands / Portal steps |
|---|---|---|
| 0:10–0:15 | Create Resource Group, Azure Managed Redis (Basic SKU), Azure Blob Storage | `az group create` · `az redis create` |
| 0:15–0:20 | Deploy Azure API Management (Consumption tier for Solutions A/B; VNet-capable for Solution C) | Portal or `az apim create` |
| 0:20–0:25 | Register Entra ID App; create User-Assigned Managed Identity for the agent | `az ad app create` · `az identity create` |
| 0:25–0:30 | Configure APIM `validate-jwt` policy and LLM backend (Azure OpenAI) | APIM policy editor |

---

## Prerequisites

- Azure subscription with **Contributor** access
- Azure CLI installed and authenticated (`az login`)
- Azure OpenAI resource deployed (GPT-4o model)

---

## Step 1 — Set Environment Variables

```bash
export RESOURCE_GROUP="rg-agenthost-workshop"
export LOCATION="eastus2"
export AOAI_ENDPOINT="https://<your-aoai-resource>.openai.azure.com/"
```

---

## Step 2 — Deploy Infrastructure via Bicep

```bash
az deployment sub create \
  --location "$LOCATION" \
  --template-file main.bicep \
  --parameters \
      resourceGroupName="$RESOURCE_GROUP" \
      location="$LOCATION" \
      aoaiEndpoint="$AOAI_ENDPOINT"
```

Or run the automated script:

```bash
chmod +x setup.sh
./setup.sh
```

---

## Step 3 — Configure APIM Policy

Create API in APIM and apply the policy defined `apim-policy.xml` file:
**Tip:** replace the "<apim-agenthost-xxxxxxxxx>" with your APIM resource name

```bash
az deployment group create \
  -g $RESOURCE_GROUP  \
  -f apim-api-policy.bicep \
  --parameters \
      apimName=<apim-agenthost-xxxxxxxxx>
```

---

## Files in This Module

| File | Description |
|---|---|
| `setup.sh` | Automated bash script for full infrastructure setup |
| `main.bicep` | Bicep subscription-scoped entry point (creates Resource Group, calls core.bicep) |
| `core.bicep` | Bicep IaC template for all shared Azure resources (Redis, Storage, APIM, UAMI) |
| `apim-api-policy.bicep` | Bicep IaC template to create API in APIM and apply the policy defined `apim-policy.xml` file |
| `apim-policy.xml` | APIM policy: `validate-jwt`, rate-limit, retry, Azure OpenAI backend |

---

## Next Step

Proceed to [Module 2 — Solution A: Foundry Host Agent](../module-02/README.md).
