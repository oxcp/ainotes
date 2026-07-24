# Lab 09: Fireworks AI on Foundry

Part of **Track C: Azure AI Foundry**. This lab consumes a **partner model (Fireworks AI)** from the Foundry model catalog as a **managed, Models-as-a-Service (MaaS) endpoint** — no GPU, Kubernetes, or compute quota to manage.

Where Lab 08 (managed compute) provisions **dedicated GPU compute** you pay for by uptime, this lab consumes a **partner-hosted model** billed **per token**. It is the most hands-off way to run a high-performance open model on Azure.

## Objectives

- Discover **Fireworks AI** models in the Foundry **model catalog** (partner / community models).
- Subscribe to and deploy a Fireworks model as a **managed endpoint** (serverless / standard, OpenAI-compatible).
- Call the endpoint with the OpenAI Python client.
- Understand the cost model: partner MaaS is billed **per token**, with no dedicated compute to size or delete.

## Before delivery

Partner catalog offerings, model ids, and Marketplace terms change. The instructor must lock these placeholders before the workshop:

| Placeholder | Meaning |
|---|---|
| `<FOUNDRY_PROJECT>` | The Foundry project used to deploy the model |
| `<FIREWORKS_MODEL_ID>` | Catalog id of the chosen Fireworks AI model |
| `<FIREWORKS_ENDPOINT_NAME>` | Name of the deployed endpoint |
| `<SERVED_MODEL_NAME>` | Model name used by the client |

> ℹ️ Fireworks AI is a **partner / community** offering. Deploying it may require an **Azure Marketplace** subscription; the subscription must have permission to subscribe to Marketplace model offerings.

## Prerequisites

- A Foundry project with access to the model catalog.
- Permission to **subscribe to Azure Marketplace** model offerings.
- Azure CLI (optional, for `az ml` deployment) or the Foundry portal.

## Deploy

### Foundry portal

Model catalog → filter by **Collection = Fireworks AI** (or search) → open the model card → **Use this model** / **Deploy** → accept the Marketplace terms if prompted → create endpoint `<FIREWORKS_ENDPOINT_NAME>`. Wait until the deployment is **Succeeded**.

### Consume

Copy the endpoint **Target URI** and **Key** from the deployment's **Consume** tab, then:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r python/requirements.txt

export MODEL_BASE_URL=<FIREWORKS_ENDPOINT_TARGET_URI>   # OpenAI-compatible base, ends in /v1
export MODEL_API_KEY=<FIREWORKS_ENDPOINT_KEY>
export MODEL_NAME=<SERVED_MODEL_NAME>
python python/chat.py
```

## Success criteria

The endpoint is deployed and the Python client receives a response from the Fireworks AI model.

## Cleanup

Delete the endpoint (and cancel the Marketplace subscription if one was created) from the Foundry portal, or:

```bash
az ml serverless-endpoint delete \
  --name <FIREWORKS_ENDPOINT_NAME> \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name <FOUNDRY_PROJECT> \
  --yes
```

Token-billed MaaS endpoints do not bill for idle compute, but delete unused endpoints to avoid accidental usage.

## How this compares

| | Lab 08 — Foundry managed compute | Lab 09 — Fireworks AI on Foundry |
|---|---|---|
| Compute | Dedicated GPU (you size it) | Partner-hosted (none to manage) |
| Quota | VM core quota required | None |
| Billing | Compute core hours (idle costs) | Per token (no idle cost) |
| Model source | Open / custom / Hugging Face / NIM | Partner (Fireworks AI) |
| Best when | You need isolation, control, steady load | You want fastest time-to-value, bursty/variable load |

This completes **Track C**. Return to [Lab 10: Observability and comparison](../lab-10-observability-comparison/README.md) to compare all tracks, or the [workshop README](../../README.md).
