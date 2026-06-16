# Module 2 — Solution A: Foundry Host Agent (20 min)

## Overview

Deploy OpenClaw as an Azure AI Foundry Host Agent — the fastest managed on-ramp for ToB enterprise scenarios. Foundry handles agent lifecycle, built-in state, and native Entra ID authentication.

## Learning Objectives

- Create an Azure AI Foundry project and configure the agent runtime
- Deploy the OpenClaw agent definition with Redis state store
- Assign a Managed Identity to the agent and route LLM calls through APIM
- Trigger scale-to-zero and verify state checkpoint/restore

## Schedule

| Time | Activity |
|---|---|
| 0:30–0:35 | Create Azure AI Foundry project; configure agent runtime |
| 0:35–0:40 | Deploy OpenClaw agent definition; set state store (Redis connection string via Key Vault reference) |
| 0:40–0:45 | Assign Managed Identity to agent; test LLM call via APIM |
| 0:45–0:50 | Trigger scale-to-zero; verify state checkpoint in Blob; restore and continue conversation |

---

## Prerequisites

- Module 1 infrastructure deployed (Resource Group, Redis, Storage, APIM, UAMI)
- Azure AI Foundry resource available in your subscription

---

## Step 1 — Set Environment Variables

```bash
export RESOURCE_GROUP="rg-openclaw-workshop"
export LOCATION="eastus"
export FOUNDRY_HUB_NAME="hub-openclaw"
export FOUNDRY_PROJECT_NAME="proj-openclaw"
export IDENTITY_NAME="id-openclaw"
export REDIS_NAME="redis-openclaw"
export STORAGE_ACCOUNT="stcopenclaw"
export KV_NAME="kv-openclaw"
export APIM_ENDPOINT="https://apim-openclaw.azure-api.net"
```

---

## Step 2 — Deploy Foundry Hub and Project via Bicep

```bash
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file foundry.bicep \
  --parameters \
      location="$LOCATION" \
      hubName="$FOUNDRY_HUB_NAME" \
      projectName="$FOUNDRY_PROJECT_NAME" \
      identityName="$IDENTITY_NAME" \
      redisName="$REDIS_NAME" \
      storageAccountName="$STORAGE_ACCOUNT" \
      keyVaultName="$KV_NAME"
```

Or run the automated script:

```bash
chmod +x deploy.sh
./deploy.sh
```

---

## Step 3 — Deploy the OpenClaw Agent Definition

The `agent-definition.json` file describes the OpenClaw agent to the Foundry runtime.

```bash
# Deploy agent definition via Azure AI Foundry CLI (or REST API)
az ml agent create \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$FOUNDRY_PROJECT_NAME" \
  --file agent-definition.json
```

---

## Step 4 — Test LLM Call via APIM

```bash
# Obtain an access token using the Managed Identity
TOKEN=$(az account get-access-token \
  --resource "https://cognitiveservices.azure.com/" \
  --query accessToken --output tsv)

# Send a test request through APIM
curl -X POST "$APIM_ENDPOINT/llm-api/openai/deployments/gpt-4o/chat/completions?api-version=2024-02-01" \
  -H "Authorization: ******" \
  -H "Content-Type: application/json" \
  -H "x-agent-id: openclaw-test-001" \
  -d '{"messages":[{"role":"user","content":"Hello from OpenClaw!"}],"max_tokens":100}'
```

---

## Step 5 — Trigger Scale-to-Zero and Verify State Restore

```bash
# Observe the agent state in Blob Storage after idle eviction
az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "openclaw-state" \
  --auth-mode login \
  --output table
```

---

## Files in This Module

| File | Description |
|---|---|
| `deploy.sh` | Automated bash script for Foundry Hub, Project, Key Vault, and agent deployment |
| `foundry.bicep` | Bicep IaC template for Azure AI Foundry Hub and Project |
| `agent-definition.json` | OpenClaw agent definition for the Foundry runtime |
| `apim-policy.xml` | APIM policy scoped to the Foundry agent backend |

---

## Next Step

Proceed to [Module 3 — Solution B: ACA Sandbox](../module-03/README.md).
