# 模块 5 — 总结和问答（5 分钟）

> 🌐 语言 / Language: [English](README.md) | **中文**

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

## 资源释放

> [!WARNING]
> **如果需要继续 Module-06，先不要释放资源。** Module-06 依赖 Modules 01–04 创建的共享基础设施。
>
> 如果不继续 Module-06，或 Module-06 已完成，请按顺序先运行 [Module-06 资源清理](../module-06/readme_CN.md)中的 [cleanup.sh](../module-06/cleanup.sh)，确认成功后，再运行本模块的 [cleanup.sh](./cleanup.sh)，释放 Modules 01–04 的资源。未部署 Module-06 时，其清理脚本只处理已发现的 Module-06 资源和配置。

在已登录 Azure 的 Bash 环境中，从 `agenthost` 目录执行；需要 Azure CLI 和 `jq`（存在 SandboxGroup 时还需要 `aca`）。先确认当前订阅，预览两次清理计划：

```bash
az account show --query '{subscription:id,name:name}' -o table
bash module-06/cleanup.sh  # 如果还没有开始module-06资源部署，可以忽略这一步
bash module-05/cleanup.sh
```

确认目标正确、重要数据已备份后，依次执行：

```bash
bash module-06/cleanup.sh --execute # 如果还没有开始module-06资源部署，可以忽略这一步

bash module-05/cleanup.sh --execute # 如果不需要上一步，或上一步已经成功后再继续
```

Module-06 要求输入 `delete module-06`；本模块要求输入 `delete <资源组名称>`，默认是 `delete rg-agenthost-workshop`。任一步失败时停止，检查错误，不要跳过失败继续删除。预览和执行时须使用相同的环境变量。

本脚本优先使用已有环境变量，未设置或为空时采用以下默认值：

| 环境变量 | 默认值 |
|---|---|
| `RESOURCE_GROUP` | `rg-agenthost-workshop` |
| `SUBSCRIPTION_ID` | Azure CLI 当前订阅 |
| `DEPLOYMENT_SN` | 目标资源组 tag `deploymentSN`；已有值必须与 tag 一致，否则停止 |
| `AKS_NAME` | `aks-agenthost-<deploymentSN>` |
| `DEPLOYMENT_NAME` | `main-<deploymentSN>` |

例如：`RESOURCE_GROUP=<资源组> SUBSCRIPTION_ID=<订阅 GUID> bash module-05/cleanup.sh`。名称覆盖不会扩大 Private Endpoint/NIC 的筛选范围，但最后会删除整个选定资源组，请仔细检查。

默认清理 `rg-agenthost-workshop`，并按顺序执行（设置环境变量时使用对应目标）：

1. 使用 `aca sandboxgroup delete --yes` 删除选定资源组中的所有 ACA SandboxGroup，显式指定订阅、资源组及各组所在区域。等待删除完成并确认组已不存在后，才继续后续步骤；没有组时跳过。删除或验证失败则停止全部后续步骤。有价值的 Sandbox 状态须先备份到组外，组内快照不属于外部备份。
2. 删除该资源组中、位于 AKS 所在 VNet 的 Private Endpoint 和 NIC。AKS 自建 VNet 从节点资源组发现；只选择目标 VNet 内的网络资源。Private Endpoint 的受管 NIC 通常由 Azure 自动删除，脚本只补删仍存在的选中 NIC；若 NIC 关联 VM，则停止并要求人工检查。
3. 删除 `aks-agenthost-<deploymentSN>`，等待完成；AKS 的托管节点资源组也随之删除。
4. 删除 `rg-agenthost-workshop` 中的 deployment 记录。
5. 删除订阅 deployment `main-<deploymentSN>`。脚本在任何删除前，从资源组 tag `deploymentSN` 读取并保存该值；缺失或无效则停止，不猜测部署名称。
6. 删除整个 `rg-agenthost-workshop`，并检查资源组已不存在。

**最后一步会删除该资源组内的所有剩余资源和数据，包括并非本研讨会创建的资源**；必须先检查资源组内容。删除 deployment 记录本身不会删除其部署的资源。本脚本不清除本地 kubeconfig、Entra 应用注册或其他资源组中的独立资源；这些不随此资源组删除的对象需另行检查。

---

## 后续步骤

- 查看 [Azure 上的智能体托管研讨会](../agenthost.md)设计文档
- 探索 [Azure AI Foundry 文档](https://learn.microsoft.com/en-us/azure/ai-studio/)
- 查看 [ACA Sandbox 概述](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview)，了解生产就绪情况
- 探索 [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) `SandboxWarmPool`，了解模块 3 中的预热沙盒

---

*核心研讨会结束 — Azure 上的智能体托管，145 分钟。*

继续学习 [Module 06：多智能体业务场景](../module-06/readme_CN.md)，建议再安排 60 分钟；
核心研讨会与本扩展模块合计 205 分钟（3 小时 25 分钟）。

---

[⬆ 返回研讨会主页](../README_CN.md)
