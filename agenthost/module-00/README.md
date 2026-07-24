# Module 0 — Introduction (10 min)

[⬆ Back to Workshop Home](../readme.md)

## Overview

This module introduces the agent hosting framework and explains why hosting it on Azure is a compelling choice for both enterprise (ToB) and consumer (ToC) scenarios.

> 📊 **Prefer slides?** Open [slides](https://oxcp.github.io/ainotes/agenthost/module-00/) for a slide-based walkthrough of the workshop content and design.
>
> 📥 **Download the slides:** [Agent-Hosting-on-Azure-Workshop-Intro.pdf](Agent-Hosting-on-Azure-Workshop-Intro.pdf) — a PDF deck introducing the workshop content and design.

## Learning Objectives

- Understand what a hosted agent is and its core architecture
- Recognise the three Azure hosting solutions covered in this workshop
- Identify the key Azure components: APIM, Entra ID, and Blob Storage

---

## What are included in our Agent?

A hosted agent is a stateful AI agent runtime. Each agent instance:

- Maintains persistent conversation context across multiple turns
- Authenticates to LLM backends via Azure Managed Identity / Workload Identity
- Scales to zero when idle and restores state on next request
- Routes all LLM calls through Azure API Management (AI Gateway)

## Three Hosting Solutions

| Solution | Azure Resource | Best for |
|---|---|---|
| **A** | Azure AI Foundry Host Agent | ToB managed — fastest on-ramp |
| **B** | AKS + agent-sandbox | ToB high-security |
| **C** | ACA Sandbox *(Public Preview)* | ToC / ToB long-running agents |

## State Persistence Pattern

```
New request    →  Load state from Azure Blob (per-agent JSON)
Active session →  Save state to Azure Blob on every change
Scale-to-zero  →  No flush needed — latest state already durable in Blob
```

## Key Components

- **Azure API Management (APIM)** — AI Gateway for token validation, rate limiting, and LLM routing
- **Azure Blob Storage** — Agent state store (per-agent JSON, versioned, cost-effective)
- **Azure Entra ID** — Authentication via Managed Identity / Workload Identity

---

## Next Step

Proceed to [Module 1 — Core Infrastructure Setup](../module-01/README.md) to provision the shared Azure resources used across all three solutions.

---

[⬆ Back to Workshop Home](../readme.md)
