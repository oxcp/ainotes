# 模块 5 — 总结和问答（5 分钟）

[⬆ 返回研讨会主页](../README_CN.md)

## 概述

回顾三种解决方案，提供决策指南，并分享生产部署的成本优化技巧。

---

## 解决方案比较回顾

| 维度 | 解决方案 A — Foundry Hosted Agent | 解决方案 B — AKS + agent-sandbox | 解决方案 C — ACA Sandbox |
|---|---|---|---|
| **隔离** | 托管（每个智能体） | 微型 VM（Kata Containers） | 服务托管的沙盒隔离（微型 VM 边界） |
| **缩容到零** | ✅ 原生 | ✅ agent-sandbox 休眠 | ✅ 原生 |
| **状态持久化** | ✅ 内置 | Azure Blob（每个智能体一个 JSON） | Azure Blob（每个智能体一个 JSON） |
| **Entra ID 身份验证** | ✅ 原生 | AAD Workload Identity | UAMI Workload Identity |
| **APIM 集成** | ✅ 原生 | ✅ 可配置 | ✅ 可配置 |
| **运维复杂度** | 低 | 高 | 中 |
| **成本** | 按执行付费 | agent-sandbox 休眠 + Spot | 无服务器 |
| **最适合** | ToB 托管快速入门；强大的治理和安全性 | ToB / ToC — 高度可定制（企业特定要求；成本/性能优化） | ToC / ToB 长时间运行的无服务器智能体 |
| **状态** | GA | GA | GA |

---

## 决策指南

```
┌─────────────────────────────────────────────────────────────────┐
│  应该选择哪种解决方案？                                         │
├─────────────────────────────────────────────────────────────────┤
│  面向企业、最快捷的托管入门路径？                                │
│    → 解决方案 A (Azure AI Foundry Hosted Agent)                 │
│                                                                 │
│  长时间运行的有状态智能体、强隔离、无服务器？                    │
│    → 解决方案 C (ACA Sandbox)                                   │
│                                                                 │
│  最大程度的定制（企业要求或成本/性能优化）？                     │
│    → 解决方案 B (AKS + agent-sandbox)                           │
│                                                                 │
│  一次性/短期代码执行（例如代码解释器）？                         │
│    → ACA Dynamic Sessions（未深入介绍，请参阅说明）              │
└─────────────────────────────────────────────────────────────────┘
```
> [!IMPORTANT]
> **ACA Dynamic Sessions** 专为**一次性或短期代码执行**（例如沙盒化代码解释器任务）而设计。其激进的会话逐出机制使其不适合长时间运行的有状态智能体。对于持久性智能体工作负载，请使用 **ACA Sandbox**。

---

## 成本优化技巧

| 调节手段 | 影响 | 适用于 |
|---|---|---|
| 缩容到零（空闲 15 分钟） | 消除非工作时段的计算成本 | A · B · C |
| APIM Basic v2 SKU | 符合 Foundry 原生 AI Gateway 的条件；固定基准成本 | A · B · C |
| 对冷状态使用 Blob Cool 层 | 比 Hot 层便宜约 50% | A · B · C |
| Blob 生命周期管理 | 自动分层或使过期智能体状态到期，以降低存储成本 | A · B · C |
| AKS Spot Node Pool | 可中断工作负载最高可享 90% 折扣 | B |
| Azure OpenAI PTU（预留吞吐量） | 为高容量 ToB 提供可预测的成本 | A · B · C |
| agent-sandbox WarmPool 优化 | 在冷启动延迟与计算节省之间取得平衡 | B |

---

## 生产环境强化清单

- [ ] 为 APIM 和 AKS 启用专用网络（VNet 注入）
- [ ] 为状态恢复启用 Blob Storage 版本控制和软删除
- [ ] 应用 Azure Policy 以确保资源合规性（标记、SKU 限制）
- [ ] 为 APIM 4xx/5xx 错误率设置 Azure Monitor 警报
- [ ] 在 AKS 上启用 Defender for Containers
- [ ] 在 Entra ID 中为 ToB 场景配置 Conditional Access 策略
- [ ] 测试 BCDR：验证 Pod/容器重启后是否能从 Blob 恢复智能体状态
- [ ] 在投入生产前验证 ACA Sandbox 的区域可用性、配额、服务限制和 SLA

---

## 后续步骤

- 查看 [Azure 上的智能体托管研讨会](../agenthost.md)设计文档
- 探索 [Azure AI Foundry 文档](https://learn.microsoft.com/en-us/azure/ai-studio/)
- 查看 [ACA Sandbox 概述](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview)，了解生产就绪情况
- 探索 [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) `SandboxWarmPool`，了解模块 3 中的预热沙盒

---

*研讨会结束 — Azure 上的智能体托管，135 分钟。*

---

[⬆ 返回研讨会主页](../README_CN.md)
