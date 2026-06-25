# Module 3 — Solution B: ACA Sandbox (30 min)

## Overview

Deploy the agent as a containerised workload on **Azure Container Apps (ACA) Sandbox** — an OS-level gVisor-isolated container environment for long-running stateful agents. This solution supports true scale-to-zero with AMR-first state persistence.

> **Note:** ACA Sandbox is currently in **Public Preview**. Verify feature availability and SLA before using in production. See [ACA Sandbox overview](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview).

## Learning Objectives

- Create an ACA Environment with the Sandbox feature enabled
- Build and push the agent container image to Azure Container Registry (ACR)
- Configure ACA app with Sandbox isolation and a scale-to-zero lifecycle hook
- Test end-to-end flow and verify state restore from Blob after idle eviction

## Schedule

| Time | Activity |
|---|---|
| 0:50–0:55 | Create ACA Environment; enable Sandbox feature (note: Public Preview) |
| 0:55–1:00 | Push agent container image to ACR; configure ACA app with Sandbox isolation and lifecycle hook (flush AMR state to Blob on scale-to-zero) |
| 1:00–1:05 | Test end-to-end: send requests, observe container isolation, trigger idle timeout, verify state restore |
| 1:05–1:15 | Deep dive: Sandbox networking, resource limits, and debugging tools; hands-on configuration of scaling policies |
| 1:15–1:20 | Comparison moment: ACA Sandbox (long-running, gVisor) vs ACA Dynamic Sessions (short-lived/one-time) |

---

## Prerequisites

- Module 1 infrastructure deployed (Redis, Blob Storage, APIM, UAMI)
- Docker CLI installed and running
- Azure Container Registry (ACR) available (created by `deploy.sh`)

---

## Step 1 — Set Environment Variables

```bash
export RESOURCE_GROUP="rg-agenthost-workshop"
export LOCATION="eastus"
export ACR_NAME="acragenthost"
export ACA_ENV_NAME="aca-env-agenthost"
export ACA_APP_NAME="agent-host"
export REDIS_NAME="redis-agenthost"
export STORAGE_ACCOUNT="stcagenthost"
export IDENTITY_NAME="id-agenthost"
export APIM_ENDPOINT="https://apim-agenthost.azure-api.net"
```

---

## Step 2 — Build and Push Container Image

```bash
# Build the agent container image
docker build -t agent-host:latest .

# Log in to ACR and push
az acr login --name "$ACR_NAME"
docker tag agent-host:latest "${ACR_NAME}.azurecr.io/agent-host:latest"
docker push "${ACR_NAME}.azurecr.io/agent-host:latest"
```

---

## Step 3 — Deploy ACA Environment and App via Bicep

```bash
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file aca.bicep \
  --parameters \
      location="$LOCATION" \
      acrName="$ACR_NAME" \
      acaEnvName="$ACA_ENV_NAME" \
      acaAppName="$ACA_APP_NAME" \
      redisName="$REDIS_NAME" \
      storageAccountName="$STORAGE_ACCOUNT" \
      identityName="$IDENTITY_NAME" \
      apimEndpoint="$APIM_ENDPOINT"
```

Or run the automated script:

```bash
chmod +x deploy.sh
./deploy.sh
```

---

## Step 4 — Test End-to-End

```bash
# Get the ACA app FQDN
ACA_FQDN=$(az containerapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACA_APP_NAME" \
  --query properties.configuration.ingress.fqdn \
  --output tsv)

# Send a test request
curl -X POST "https://$ACA_FQDN/chat" \
  -H "Content-Type: application/json" \
  -H "x-agent-id: agent-test-001" \
  -d '{"message": "Hello from ACA Sandbox!"}'
```

---

## Step 5 — Verify State Restore After Scale-to-Zero

```bash
# List state snapshots in Blob (written by lifecycle-hook.sh on scale-to-zero)
az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "agent-state" \
  --auth-mode login \
  --output table
```

---

## Files in This Module

| File | Description |
|---|---|
| `deploy.sh` | Automated bash script: ACR, ACA Environment, ACA App deployment |
| `aca.bicep` | Bicep IaC template for ACR, ACA Environment, and ACA App with Sandbox |
| `Dockerfile` | Container image for the agent runtime |
| `container-app.yaml` | ACA containerapp YAML manifest (alternative to Bicep) |
| `lifecycle-hook.sh` | Scale-to-zero hook: flushes AMR state to Azure Blob on container shutdown |

---

## ACA Sandbox vs ACA Dynamic Sessions

| Aspect | ACA Sandbox | ACA Dynamic Sessions |
|---|---|---|
| Isolation | OS-level gVisor (syscall interception) | Per-session container sandbox |
| Session lifetime | Long-running (persistent agent) | Short-lived / one-time execution |
| State | Persistent across requests | Evicted aggressively |
| Best for | Long-running stateful AI agents | Code interpreter, ephemeral tasks |
| Status | Public Preview | GA |

---

## Next Step

Proceed to [Module 4 — Solution C: AKS + E2B](../module-04/README.md).
