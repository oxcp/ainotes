# Module 0 — Introduction (10 min)

[⬆ Back to Workshop Home](../readme.md)

## Overview

This module introduces the agent hosting framework and explains why hosting it on Azure is a compelling choice for both enterprise (ToB) and consumer (ToC) scenarios.

## Learning Objectives

- Understand what a hosted agent is and its core architecture
- Recognise the three Azure hosting solutions covered in this workshop
- Identify the key Azure components: APIM, Entra ID, Redis, and Blob Storage

---

## What is a hosted agent?

A hosted agent is a stateful AI agent runtime. Each agent instance:

- Maintains persistent conversation context across multiple turns
- Authenticates to LLM backends via Azure Managed Identity / Workload Identity
- Scales to zero when idle and restores state on next request
- Routes all LLM calls through Azure API Management (AI Gateway)

## Three Hosting Solutions

| Solution | Azure Resource | Best for |
|---|---|---|
| **A** | Azure AI Foundry Host Agent | ToB managed — fastest on-ramp |
| **B** | ACA Sandbox *(Public Preview)* | ToC / ToB long-running agents |
| **C** | AKS + Self-built E2B | ToB high-security |

## State Persistence Pattern

```
New request    →  Load from Azure Managed Redis (AMR); fallback to Blob
Active session →  Dual-write to AMR + Blob
Scale-to-zero  →  Flush AMR state to Azure Blob (cool tier)
```

## Key Components

- **Azure API Management (APIM)** — AI Gateway for token validation, rate limiting, and LLM routing
- **Azure Managed Redis (AMR)** — Hot state store (sub-millisecond latency)
- **Azure Blob Storage** — Cold snapshot store (versioned, cost-effective)
- **Azure Entra ID** — Authentication via Managed Identity / Workload Identity

---

## Next Step

Proceed to [Module 1 — Core Infrastructure Setup](../module-01/README.md) to provision the shared Azure resources used across all three solutions.

---

[⬆ Back to Workshop Home](../readme.md)
