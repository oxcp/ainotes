# Module 5 — Wrap-up and Q&A (5 min)

[⬆ Back to Workshop Home](../readme.md)

## Overview

Recap the three solutions, provide decision guidance, and share cost optimisation tips for production deployments.

---

## Solution Comparison Recap

| Dimension | Solution A — Foundry Host Agent | Solution B — AKS + E2B | Solution C — ACA Sandbox |
|---|---|---|---|
| **Isolation** | Managed (per-agent) | Micro-VM (Kata Containers) | OS-level gVisor |
| **Scale-to-zero** | ✅ Native | ✅ KEDA | ✅ Native |
| **State persistence** | ✅ Built-in | AMR + Blob (CSI) | AMR + Blob |
| **Entra ID auth** | ✅ Native | AAD Workload Identity | UAMI Workload Identity |
| **APIM integration** | ✅ Native | ✅ VNet-injected | ✅ |
| **Operational complexity** | Low | High | Medium |
| **Cost** | Pay-per-exec | KEDA zero-scale + Spot | Serverless |
| **Best for** | ToB managed fast on-ramp | ToB high-security | ToC / ToB long-running agents |
| **Status** | GA | GA | Public Preview |

---

## Decision Guidance

```
┌─────────────────────────────────────────────────────────────────┐
│  Which solution should I choose?                                │
├─────────────────────────────────────────────────────────────────┤
│  Fastest managed on-ramp for enterprise?                        │
│    → Solution A (Azure AI Foundry Host Agent)                   │
│                                                                 │
│  Long-running stateful agents, strong isolation, serverless?    │
│    → Solution C (ACA Sandbox)                                   │
│                                                                 │
│  Maximum control, Micro-VM isolation, private networking?       │
│    → Solution B (AKS + E2B)                                     │
│                                                                 │
│  One-time / short-lived code execution (e.g. code interpreter)? │
│    → ACA Dynamic Sessions (not covered in depth, see note)      │
└─────────────────────────────────────────────────────────────────┘
```

> **ACA Dynamic Sessions** is designed for **one-time or short-lived code execution** (e.g. sandboxed code interpreter tasks). Its aggressive session eviction makes it unsuitable for long-running stateful agents. Use **ACA Sandbox** for persistent agent workloads.

---

## Cost Optimisation Tips

| Lever | Impact | Applies to |
|---|---|---|
| Scale-to-zero (30-min idle) | Eliminate compute cost during off-hours | A · B · C |
| APIM Basic v2 SKU | Eligible for Foundry native AI Gateway; fixed baseline cost | A · B · C |
| Azure Managed Redis Basic SKU | ~60% cheaper than Standard for dev/test | A · B · C |
| Blob Cool tier for cold state | ~50% cheaper than Hot tier | A · B · C |
| Redis TTL tuning | Auto-evict stale agent state; reduce memory cost | A · B · C |
| AKS Spot Node Pool | Up to 90% discount for interruptible workloads | B |
| Azure OpenAI PTU (reserved throughput) | Predictable cost for high-volume ToB | A · B · C |
| KEDA cooldown tuning | Balance cold-start latency vs compute savings | B |

---

## Production Hardening Checklist

- [ ] Enable private networking (VNet injection) for APIM and AKS
- [ ] Configure Azure Managed Redis with TLS 1.2 and at-rest encryption
- [ ] Enable Blob Storage versioning and soft delete for state recovery
- [ ] Apply Azure Policy for resource compliance (tags, SKU restrictions)
- [ ] Set up Azure Monitor alerts for APIM 4xx/5xx error rates
- [ ] Enable Defender for Containers on AKS
- [ ] Rotate Redis keys via Azure Key Vault rotation policy
- [ ] Configure Conditional Access policies in Entra ID for ToB scenarios
- [ ] Test BCDR: simulate Redis failure and verify Blob restore path
- [ ] Review ACA Sandbox SLA and feature completeness before production (Public Preview)

---

## Next Steps

- Review the [Agent Hosting on Azure Workshop](../agenthost.md) design document
- Explore the [Azure AI Foundry documentation](https://learn.microsoft.com/en-us/azure/ai-studio/)
- Review [ACA Sandbox overview](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview) for production readiness
- Consider [KEDA HTTP Add-on](https://github.com/kedacore/http-add-on) for HTTP-driven scaling in Module 3

---

*Workshop completed — Agent Hosting on Azure, 120 minutes.*

---

[⬆ Back to Workshop Home](../readme.md)
