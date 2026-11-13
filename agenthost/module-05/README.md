# Module 5 — Wrap-up and Q&A (5 min)

> 🌐 语言 / Language: **English** | [中文](README_CN.md)

[⬆ Back to Workshop Home](../readme.md)

## Overview

Recap the three solutions, provide decision guidance, and share cost-optimization tips for production deployments.

---

## Solution Comparison Recap

| Dimension | Solution A — Foundry Hosted Agent | Solution B — AKS + agent-sandbox | Solution C — ACA Sandbox |
|---|---|---|---|
| **Isolation** | Managed (per-agent) | Micro-VM (Kata Containers) | Service-managed sandbox isolation (micro-VM boundary) |
| **Scale-to-zero** | ✅ Native | ✅ agent-sandbox hibernate | ✅ Native |
| **State persistence** | ✅ Built-in | Azure Blob (per-agent JSON) | Azure Blob (per-agent JSON) |
| **Entra ID auth** | ✅ Native | AAD Workload Identity | UAMI Workload Identity |
| **APIM integration** | ✅ Native | ✅ Configurable | ✅ Configurable |
| **Operational complexity** | Low | High | Medium |
| **Cost** | Pay-per-exec | agent-sandbox hibernate + Spot | Serverless |
| **Best for** | ToB managed fast on-ramp; strong governance and security | ToB / ToC — high customization (enterprise-specific requirements; cost/performance tuning) | ToC / ToB long-running, serverless agents |
| **Status** | GA | GA | GA |

---

## Decision Guidance

```
┌─────────────────────────────────────────────────────────────────┐
│  Which solution should I choose?                                │
├─────────────────────────────────────────────────────────────────┤
│  Fastest managed on-ramp for enterprise?                        │
│    → Solution A (Azure AI Foundry Hosted Agent)                 │
│                                                                 │
│  Long-running stateful agents, strong isolation, serverless?    │
│    → Solution C (ACA Sandbox)                                   │
│                                                                 │
│  Maximum customization (enterprise reqs or cost/perf tuning)?   │
│    → Solution B (AKS + agent-sandbox)                           │
│                                                                 │
│  One-time / short-lived code execution (e.g. code interpreter)? │
│    → ACA Dynamic Sessions (not covered in depth, see note)      │
└─────────────────────────────────────────────────────────────────┘
```
> [!IMPORTANT]
> **ACA Dynamic Sessions** is designed for **one-time or short-lived code execution** (e.g. sandboxed code interpreter tasks). Its aggressive session eviction makes it unsuitable for long-running stateful agents. Use **ACA Sandbox** for persistent agent workloads.

---

## Cost Optimization Tips

| Lever | Impact | Applies to |
|---|---|---|
| Scale-to-zero (15-min idle) | Eliminate compute cost during off-hours | A · B · C |
| APIM Basic v2 SKU | Eligible for Foundry native AI Gateway; fixed baseline cost | A · B · C |
| Blob Cool tier for cold state | ~50% cheaper than Hot tier | A · B · C |
| Blob lifecycle management | Auto-tier or expire stale agent state to reduce storage cost | A · B · C |
| AKS Spot Node Pool | Up to 90% discount for interruptible workloads | B |
| Azure OpenAI PTU (reserved throughput) | Predictable cost for high-volume ToB | A · B · C |
| agent-sandbox WarmPool tuning | Balance cold-start latency vs compute savings | B |

---

## Production Hardening Checklist

- [ ] Enable private networking (VNet injection) for APIM and AKS
- [ ] Enable Blob Storage versioning and soft delete for state recovery
- [ ] Apply Azure Policy for resource compliance (tags, SKU restrictions)
- [ ] Set up Azure Monitor alerts for APIM 4xx/5xx error rates
- [ ] Enable Defender for Containers on AKS
- [ ] Configure Conditional Access policies in Entra ID for ToB scenarios
- [ ] Test BCDR: verify agent state restores from Blob after a pod/container restart
- [ ] Validate ACA Sandbox regional availability, quotas, service limits, and SLA before production

---

## Resource Cleanup

> [!WARNING]
> **Do not release resources yet if you plan to continue with Module-06.** Module-06 depends on the shared infrastructure created by Modules 01–04.
>
> If you are not continuing with Module-06, or have finished it, first run [cleanup.sh](../module-06/cleanup.sh) following the [Module-06 cleanup instructions](../module-06/readme.md). After it succeeds, run this module's [cleanup.sh](./cleanup.sh) to release Modules 01–04 resources. If Module-06 was not deployed, its cleanup only processes discovered Module-06 resources and configuration.

Use a Bash environment signed in to Azure, with Azure CLI and `jq` installed (`aca` is also required if SandboxGroups exist). From the `agenthost` directory, confirm the subscription and preview both cleanup plans:

```bash
az account show --query '{subscription:id,name:name}' -o table
bash module-06/cleanup.sh  # Skip this step if Module-06 resource deployment has not started
bash module-05/cleanup.sh
```

After confirming the targets and backing up important data, execute in order:

```bash
bash module-06/cleanup.sh --execute # Skip this step if Module-06 resource deployment has not started

bash module-05/cleanup.sh --execute # Continue if the previous step is unnecessary or has succeeded
```

Module-06 requires typing `delete module-06`; this module requires `delete <resource-group-name>`, defaulting to `delete rg-agenthost-workshop`. Stop on any failure and investigate the error rather than continuing deletion. Use the same environment variables for preview and execution.

The script uses existing environment variables first, applying these defaults when they are unset or empty:

| Environment variable | Default |
|---|---|
| `RESOURCE_GROUP` | `rg-agenthost-workshop` |
| `SUBSCRIPTION_ID` | The active Azure CLI subscription |
| `DEPLOYMENT_SN` | The target resource group's `deploymentSN` tag; an existing value must match the tag or cleanup stops |
| `AKS_NAME` | `aks-agenthost-<deploymentSN>` |
| `DEPLOYMENT_NAME` | `main-<deploymentSN>` |

For example: `RESOURCE_GROUP=<resource-group> SUBSCRIPTION_ID=<subscription GUID> bash module-05/cleanup.sh`. Name overrides do not widen Private Endpoint/NIC filtering, but the final step deletes the entire selected group; inspect it carefully.

By default, the script cleans up `rg-agenthost-workshop` in this order (environment overrides select the corresponding targets):

1. Delete all ACA SandboxGroups in the selected resource group using `aca sandboxgroup delete --yes`, with explicit subscription, resource group and each group's region. Wait for deletion and verify the groups are absent before continuing. If no groups exist, skip this step. Deletion or verification failure stops all later steps. Back up valuable Sandbox state outside the group first; snapshots stored inside the group are not an external backup.
2. Delete Private Endpoints and NICs in that resource group that belong to the AKS VNet. AKS-managed VNets are discovered in the node resource group; only network resources in the target VNet are selected. Azure normally deletes a Private Endpoint's managed NIC automatically; the script deletes selected NICs only if they remain. A NIC attached to a VM causes cleanup to stop for manual review.
3. Delete `aks-agenthost-<deploymentSN>` and wait for completion; AKS also deletes its managed node resource group.
4. Delete deployment records in `rg-agenthost-workshop`.
5. Delete the subscription deployment `main-<deploymentSN>`. Before any deletion, the script reads and saves `deploymentSN` from the resource group's tags. Missing or invalid values stop cleanup instead of guessing a deployment name.
6. Delete the entire `rg-agenthost-workshop` and verify that the group no longer exists.

**The final step deletes every remaining resource and its data in this group, including resources not created by the workshop**; inspect the group's contents first. Deleting deployment records alone does not delete deployed resources. This script does not remove local kubeconfig entries, Entra app registrations, or independent resources in other groups; review those separately because they are not removed with this resource group.

---

## Next Steps

- Review the [Agent Hosting on Azure Workshop](../agenthost.md) design document
- Explore the [Azure AI Foundry documentation](https://learn.microsoft.com/en-us/azure/ai-studio/)
- Review [ACA Sandbox overview](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview) for production readiness
- Explore [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) `SandboxWarmPool` for pre-warmed sandboxes in Module 3

---

*Core workshop complete — Agent Hosting on Azure, 145 minutes.*

Continue with [Module 06: Multi-Agent Business Scenarios](../module-06/readme.md) for a suggested
60-minute extension; the core workshop plus this extension totals 205 minutes (3 hours 25 minutes).

---

[⬆ Back to Workshop Home](../readme.md)
