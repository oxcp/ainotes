# Lab 08: Azure AI Foundry — Managed Compute

Part of **Track C: Azure AI Foundry**. This lab consumes Azure GPU through Foundry's highest-level managed path: deploying an open model from the Foundry model catalog onto a **dedicated managed online endpoint (managed compute)**, then calling it.

Unlike Track A (AKS + KAITO), you do **not** operate Kubernetes. Foundry provisions and manages the GPU-backed compute; you own only the deployment configuration and the client.

## Objectives

- Select an open model in the Foundry **model catalog** that supports the **Managed compute** deployment option.
- Create a **managed online endpoint** and a **model deployment** on dedicated GPU compute.
- Consume the deployment (OpenAI-compatible chat for LLMs, or the `/score` endpoint for other tasks).
- Understand the cost model: managed compute is billed **per compute uptime (core hours)** and consumes **VM core quota** per region.

## Before delivery

Managed compute is version- and region-sensitive. The instructor must lock these placeholders before the workshop:

| Placeholder | Meaning |
|---|---|
| `<FOUNDRY_HUB_PROJECT>` | The AI Hub–based Foundry project (managed compute requires an AI Hub resource) |
| `<MANAGED_COMPUTE_MODEL_ID>` | Catalog model id, e.g. `azureml://registries/azureml/models/<model>/versions/<n>` |
| `<GPU_VM_SKU>` | GPU VM SKU with confirmed quota, e.g. `Standard_NC24ads_A100_v4` |
| `<ENDPOINT_NAME>` | Unique managed online endpoint name (per region) |
| `<SERVED_MODEL_NAME>` | Model name used by the client |

> ⚠️ **Cost:** Managed compute bills while the endpoint is provisioned, even when idle. Delete the deployment and endpoint as soon as the lab is complete (see Cleanup).

## Prerequisites

- An **AI Hub–based** Foundry project (managed compute is not available on standalone Foundry resources).
- **Azure AI Developer** role on the resource group.
- **VM core quota** for `<GPU_VM_SKU>` in the target region.
- Azure CLI with the ML extension (`az extension add -n ml`) or the Python SDK (`azure-ai-ml`, `azure-identity`).

## Deploy

### Option A — Azure CLI (`az ml`)

Edit [configs/deployment.template.yaml](configs/deployment.template.yaml) with your locked values, then:

```bash
# Create the endpoint (a container for one or more deployments)
az ml online-endpoint create \
  --name <ENDPOINT_NAME> \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name <FOUNDRY_HUB_PROJECT>

# Create the model deployment on GPU compute and route 100% traffic to it
az ml online-deployment create \
  --file configs/deployment.template.yaml \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name <FOUNDRY_HUB_PROJECT> \
  --all-traffic
```

### Option B — Foundry portal

Model catalog → set **Deployment options** filter to **Managed compute** → open the model card → **Use this model** → pick `<GPU_VM_SKU>`, instance count `1`, create a new endpoint `<ENDPOINT_NAME>` → **Deploy**. Wait until **Provisioning state = Succeeded** and **Deployment state = Healthy**.

## Consume

Get the endpoint **Target URI** and **Key** from the deployment's **Details** / **Consume** tab, then:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r python/requirements.txt

# For OpenAI-compatible LLM deployments
export MODEL_BASE_URL=https://<ENDPOINT_NAME>.<region>.inference.ml.azure.com/v1
export MODEL_API_KEY=<ENDPOINT_KEY>
export MODEL_NAME=<SERVED_MODEL_NAME>
python python/chat.py
```

> Some managed-compute models expose a `/score` REST endpoint instead of an OpenAI-compatible `/v1` route. Check the model card's **Consume** tab and adjust the client accordingly.

## Success criteria

The endpoint is **Healthy**, the deployment shows **Succeeded**, and the Python client receives a model response.

## Cleanup

```bash
az ml online-endpoint delete \
  --name <ENDPOINT_NAME> \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name <FOUNDRY_HUB_PROJECT> \
  --yes
```

Deleting the endpoint removes its deployments and stops compute billing.

## How this compares

| | Lab 02 — AKS + KAITO | Lab 08 — Foundry managed compute |
|---|---|---|
| You operate Kubernetes | Yes | No |
| GPU compute | Your AKS GPU node pool | Foundry-managed dedicated compute |
| Quota consumed | AKS GPU node pool | VM core quota (per region) |
| Billing | AKS node uptime | Managed compute core hours |
| Best when | You want K8s-native control | You want a managed endpoint without operating K8s |

Continue to [Lab 09: Fireworks AI on Foundry](../lab-09-fireworks-ai-foundry/README.md) for the partner Models-as-a-Service path.
