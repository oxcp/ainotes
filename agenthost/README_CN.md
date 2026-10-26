# Azure 上的智能体托管研讨会

## 研讨会简介

本研讨会将带你踏上一段实用的 Azure 智能体托管之旅。你将从共享基础设施入手，比较适用于企业和消费者场景的三种部署方案，最后了解成本和生产环境强化指南。

<!-- > 📊 **更喜欢幻灯片？** 
>
> 打开[简介](https://oxcp.github.io/ainotes/agenthost/module-00/)，逐步浏览研讨会内容。 -->

> [!TIP]
> 为获得更好的阅读和导航体验，请使用 [Azure 上的智能体托管研讨会指南](https://oxcp.github.io/ainotes/markdown-viewer.html?file=agenthost/readme.md)。

---

## 研讨会大纲

- **目标场景**：ToB 企业场景和 ToC 消费者场景，两者在隔离、扩展、身份验证和成本方面各有不同的优先级。
- **解决方案（有关详细信息，请参阅[研讨会简介](./module-00/README.md)）**：
  - **解决方案 A**：Azure AI Foundry Hosted Agent（ToB 托管）— 最快捷的入门路径，提供原生状态和身份验证，以及强大的治理和安全性。
  - **解决方案 B**：AKS + agent-sandbox（ToB / ToC）— 高度可定制：满足 ToB 特有的企业技术要求，或针对 ToC 优化成本和性能。
  - **解决方案 C**：ACA 容器运行时选项（ToC / ToB）：
    - **研讨会路径**：ACA Sandboxes — 服务托管的沙盒隔离（微型 VM 边界），支持挂起/恢复。
    - **可选学习路径**：ACA Dynamic Sessions — 使用 Hyper-V 隔离的会话池，实现低延迟的临时执行。
- **已实现的功能**：状态持久化、缩容到零、隔离、Entra ID 身份验证以及 AI Gateway 集成。
- **研讨会日程**：120 分钟的动手研讨会，涵盖核心基础设施设置、上述三种解决方案，以及包含成本优化技巧和生产环境强化清单的总结。

## 如何使用本研讨会

1. 创建一个用于存储研讨会文件的本地目录（例如 `myworkshop`），然后进入该目录：

  ```bash
  mkdir myworkshop
  cd myworkshop
  ```

2. 使用稀疏签出克隆存储库，进入生成的 `ainotes` 目录，然后签出 `agenthost` 目录：

> [!tip]
> 您需要在 Linux 环境中运行 git 来克隆本次研讨会所需的脚本和配置。如果当前环境尚未安装 git，请先安装 git；或者参考[先决条件](#先决条件研讨会开始前)部分，使用本研讨会提供的 [toolbox VM 模板](./az-toolbox-vm/) 自动创建一台已预装 git 和本次研讨会所需工具的 VM。

  ```bash
  git clone --depth 1 --filter=blob:none --sparse https://github.com/oxcp/ainotes/
  cd ainotes
  git sparse-checkout set agenthost
  ```

这将下载 `agenthost` 研讨会所需的内容。

---

## 先决条件（研讨会开始前）

可以选择以下任一种方式，准备运行研讨会脚本和命令的环境：

1. **使用自己已有的环境**，例如 Linux 控制台、WSL 或 Azure Cloud Shell。请确保已安装研讨会所需的全部工具，并按下文说明运行 [check-prerequisites.sh](./check-prerequisites.sh)，检查工具安装状态及其他先决条件。Azure Cloud Shell 通常所需的设置最少，但长时间无人操作时可能会超时。因此，建议使用 Linux 控制台或 WSL 环境。
2. **部署工具箱 VM**，避免花时间自行设置环境和安装工具。使用 [az-toolbox-vm](./az-toolbox-vm/) 中的模板，部署一台包含研讨会执行所需工具的 VM。方式是在 Azure 门户中打开 **部署自定义模板（Deploy a custom template）**，选择 **在编辑器中生成自己的模板（Build your own template in the editor）**，然后通过 **加载文件（Load file）** 导入 [main.json](./az-toolbox-vm/main.json)。根据部署需要提供参数，例如 VNet 和子网的 IP CIDR 范围、SSH 公钥，以及受信任的 SSH 源 IP/CIDR。完整步骤和参数说明请参阅[工具箱 VM 部署指南](./az-toolbox-vm/README.md)。

> [!IMPORTANT]
> 即使使用模板部署工具箱 VM 并成功完成初始化，也只保证所需工具已就绪。您仍需确保 Azure 登录状态有效、已获得所需的 RBAC 权限，并满足研讨会的其他先决条件。可以在 VM 上运行 [check-prerequisites.sh](./check-prerequisites.sh) 检查这些要求，并根据未通过检查项的修复链接完成配置。

两种方式均需满足研讨会执行的先决条件。开始研讨会之前，请从 `agenthost` 目录运行先决条件检查器：

```bash
cd agenthost
chmod +x check-prerequisites.sh
bash check-prerequisites.sh
```

检查器按模块对结果进行分组，清晰标识已通过和未通过的要求，并为每个失败的检查提供修复链接。

输出将类似于以下内容：
> [!TIP]
> 下面的示例展示了检查器如何识别未满足的先决条件并建议后续步骤。

```text
Agent Hosting on Azure Workshop - Prerequisite Check
------
[01/14] Checking Azure CLI 2.80.0+...
[02/14] Checking active Azure login...
[03/14] Checking workshop deployment permissions...
[04/14] Checking curl installation...
[05/14] Checking jq installation...
[06/14] Checking Azure Developer CLI installation...
[07/14] Checking active azd login...
[08/14] Checking Microsoft Foundry azd extension...
[09/14] Checking Foundry User role...
[10/14] Checking kubectl installation...
[11/14] Checking ACR remote build permissions...
[12/14] Checking Azure CLI support for AKS Pod Sandboxing...
[13/14] Checking Container Apps preview extension...
[14/14] Checking Container Apps SandboxGroup Data Owner role...

Common prerequisites for all modules
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Azure CLI 2.80.0+                        | Pass       | Installed: 2.85.0
Active Azure login                       | Pass       | <subscription-name> (<subscription-id>)
Workshop deployment permissions          | Pass       | All 26 required ARM actions are allowed

Module 01
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
curl installed                           | Pass       | Installed: 8.15.0
jq installed                             | Pass       | Installed: 1.8.1

Module 02
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Azure Developer CLI installed            | Pass       | Installed: 1.27.0
Active azd login                         | Pass       | azd authentication is active
Microsoft Foundry azd extension          | Pass       | microsoft.foundry is installed
Foundry User role                        | Failed     | Role assignment not found for the current subscription

Fix suggestion:
- Foundry User role: https://learn.microsoft.com/azure/ai-foundry/concepts/rbac-azure-ai-foundry

Module 03
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
kubectl installed                        | Pass       | Installed: v1.35.0
ACR remote build permissions             | Skipped    | No container registry was found in rg-agenthost-workshop; check again after deploying Module 01
Azure CLI for AKS Pod Sandboxing         | Pass       | Installed: 2.85.0

Module 04
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Container Apps preview extension         | Pass       | containerapp 1.3.0b4 (preview enabled)
SandboxGroup Data Owner role             | Failed     | Role assignment not found for the current subscription

Fix suggestion:
- SandboxGroup Data Owner role: https://learn.microsoft.com/azure/container-apps/sandboxes

Summary: 11 passed, 1 skipped, 2 failed
Workshop readiness: Ready to start.
Module notice: Resolve the failed Module 02 prerequisite(s) before starting that module.
Module notice: Resolve the failed Module 04 prerequisite(s) before starting that module.
Module notice: Re-run this check after Module 01 to validate the skipped ACR permission before Module 03.
```
> [!TIP]
> 1. 如果**所有模块的通用先决条件**和**模块 01**中没有失败的检查，脚本会报告 `Workshop readiness: Ready to start`，此时你可以开始研讨会。
> 2. **模块 02** 到**模块 04**中的失败检查不会阻止你开始研讨会。请按照报告的详细信息和修复建议进行处理，然后在开始对应模块之前再次运行 `check-prerequisites.sh`。只有在该模块的所有先决条件均得到满足后，才开始该模块。
> 3. 在研讨会开始之前，Azure Container Registry 尚未部署，因此 `check-prerequisites.sh` 会将 **ACR 远程生成权限**检查报告为 `Skipped`。完成模块 01 后，请再次运行检查器以验证这些权限。模块 03 使用 `az acr build`。在注册表范围内分配 **Contributor** 足以执行生成和映像推送操作。
> 4. **模块 03** 和**模块 04**共享同一个 Azure Container Registry 和容器映像。因此，已部署且可访问的 ACR 是模块 03 和模块 04 的先决条件，即使 ACR 权限检查显示在模块 03 下也是如此。

如果“研讨会部署权限”检查发现研讨会部署所需的任何操作不被允许，检查器将列出每个缺失的 ARM 操作，如下所示：

```text
Missing 2 required ARM action(s); see the list below

Fix suggestion:
- Missing ARM action: Microsoft.Authorization/roleAssignments/write
- Missing ARM action: Microsoft.ContainerService/managedClusters/write
- Permission guidance: https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal-subscription-admin
```

---


## 研讨会模块

| 模块 | 主题 | 时长 | 目的 |
|---|---|---|---|
| [module-00](./module-00/README.md) | 简介 | 10 分钟 | 了解目标场景、智能体状态模式和三种托管解决方案。 |
| [module-01](./module-01/README.md) | 核心基础设施设置 | 20 分钟 | 部署所有托管解决方案共用的 Azure 基础设施。 |
| [module-02](./module-02/README.md) | 解决方案 A：Foundry Hosted Agent | 30 分钟 | 部署具有原生状态、身份验证、治理和 AI Gateway 集成的托管 Foundry 智能体。 |
| [module-03](./module-03/README.md) | 解决方案 B：AKS + agent-sandbox | 40 分钟 | 在 AKS 上部署可定制的智能体运行时，具备沙盒隔离、持久状态和工作负载标识。 |
| [module-04](./module-04/README.md) | 解决方案 C：ACA Sandboxes（研讨会路径） | 30 分钟 | 在 ACA Sandboxes 中部署具有微型 VM 隔离及挂起/恢复功能的智能体，并探索作为可选路径的 Dynamic Sessions。 |
| [module-05](./module-05/README.md) | 总结和问答 | 5 分钟 | 比较解决方案，并查看选择指南、成本优化和生产环境强化建议。 |

**研讨会总时长：**135 分钟。**动手练习（模块 01–04）：**120 分钟。

---

## 研讨会结构

以下列出主要目录和文件，省略单独的截图文件和生成的缓存。

```
agenthost/
├── readme.md                    ← 研讨会概述、先决条件、模块和结构
├── README_CN.md                 ← 中文研讨会指南
├── check-prerequisites.sh       ← 检查工具、Azure 登录、扩展、权限和 RBAC 角色
├── az-toolbox-vm/
│   ├── README.md                ← 工具箱 VM 部署、验证和故障排查指南
│   ├── README_CN.md             ← 中文工具箱 VM 指南
│   ├── main.bicep               ← Ubuntu 工具箱 VM 的基础设施源文件
│   ├── main.json                ← 生成的 Azure 门户自定义部署模板
│   ├── cloud-init.yaml          ← 首次启动时的工具安装和初始化配置
│   └── scripts/
│       └── verify-tools.sh      ← 验证工具版本和用户范围扩展
├── pic/                         ← 研讨会截图，包括 toolbox-vm-deployment.png
├── module-00/
│   ├── README.md                ← 体系结构决策、场景和解决方案比较
│   ├── README_CN.md             ← 中文简介指南
│   ├── design.html              ← 交互式研讨会设计幻灯片
│   ├── index.html               ← 研讨会演示页面
│   ├── timer-en.html            ← 英文研讨会计时器
│   ├── timer.html               ← 中文研讨会计时器
│   └── slides/                  ← 演示幻灯片图片
├── module-01/
│   ├── README.md                ← 核心基础设施设置步骤
│   ├── README_CN.md             ← 中文基础设施设置指南
│   ├── setup.sh                 ← 一步式包装器：运行 main.bicep 部署 (az deployment sub create)
│   ├── main.bicep               ← 订阅范围的 Bicep 入口点
│   └── core.bicep               ← 存储、APIM、标识、Foundry 项目、模型、Defender 和 AI Gateway
├── module-02/
│   ├── README.md                ← Foundry 托管智能体 azd 部署步骤
│   ├── README_CN.md             ← 中文托管智能体部署指南
│   ├── azure.yaml               ← azd init 使用的托管智能体清单（引用 agent-src）
│   ├── ai-gateway-inbound-policy.xml ← AI Gateway 的 APIM 入站策略（网关模式）
│   └── agent-src/               ← Agent Framework 应用源代码
│       ├── main.py              ← 托管智能体应用入口
│       ├── requirements.txt     ← Python 依赖项
│       ├── Dockerfile           ← 智能体容器映像
│       ├── .azdignore           ← azd 打包排除项
│       └── .dockerignore        ← 容器生成排除项
├── module-03/
│   ├── README.md                ← AKS + agent-sandbox 准备、部署、验证和体系结构说明
│   ├── README_CN.md             ← 中文 AKS 沙盒指南
│   ├── prepare-agent-sandbox.sh ← 准备 AKS、Kata 节点池、控制器、机密、Blob CSI 存储和 Sandbox 清单
│   ├── aks.bicep                ← 基线 AKS、Blob CSI、Workload Identity 联合和应用程序 UAMI Blob RBAC
│   ├── aks-kubelet-rbac.bicep   ← AKS kubelet 标识的基于主体的 AcrPull 和 Blob CSI RBAC
│   ├── deploy-storage-private-link.sh ← 可选包装器：为 AKS 专用访问部署 Blob Private Link
│   ├── storage-private-link.bicep ← 用于 Blob Private Endpoint 和 Private DNS 接线的可选 Bicep 模板
│   ├── agent-storage.yaml.example ← Blob CSI StorageClass、静态 PV 和 PVC 模板
│   ├── agent-sandbox.yaml.example ← Sandbox、Workload Identity 服务帐户、卷装载和 Service 模板
│   └── agent-src/               ← POC 智能体映像源代码（共享智能体映像的生成上下文）
│       ├── app/
│       │   ├── main.py          ← 智能体应用入口
│       │   ├── portal.html      ← 智能体聊天 Web 界面
│       │   ├── readme.md        ← 应用使用说明
│       │   └── .env.example     ← 应用环境变量示例
│       ├── Dockerfile           ← 多阶段 Python 映像（生成上下文 = agent-src/）
│       ├── requirements.txt     ← Python 依赖项
│       ├── lifecycle-hook.sh    ← SIGTERM pre-stop 挂钩：状态已持久化在 Blob 中（无操作日志）
│       ├── README.md            ← agent-src 使用说明
│       └── .dockerignore        ← 容器生成排除项
├── module-04/
│   ├── README.md                ← 研讨会路径：ACA Sandboxes；可选路径：Dynamic Sessions
│   ├── README_CN.md             ← 中文 ACA 沙盒指南
│   ├── sandbox.bicep            ← 研讨会路径：SandboxGroup（真正的 Sandboxes、微型 VM 边界、挂起/恢复）+ UAMI AcrPull 角色
│   ├── sandbox-deploy.sh        ← 研讨会路径：复用模块 03 映像 + SandboxGroup + 磁盘映像 + 沙盒管理
│   ├── dynamic-session-deploy.sh← 可选路径：会话池部署（自定义容器）
│   ├── dynamic-session-invoke.sh← 可选路径：会话池终结点的最小调用示例
│   ├── dynamic-sessions.md       ← 可选的 Dynamic Sessions 学习指南
│   └── container-app.yaml       ← 旧版标准 ACA 清单（仅供参考）
└── module-05/
    ├── README.md                ← 比较回顾、决策指南、成本技巧和生产环境清单
    └── README_CN.md             ← 中文总结指南

```

---
