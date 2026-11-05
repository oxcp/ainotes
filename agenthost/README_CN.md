# Azure 上的智能体托管研讨会

> 🌐 语言 / Language: [English](readme.md) | **中文**

## 研讨会简介

本研讨会将带你踏上一段实用的 Azure 智能体托管之旅：
- 基础部分：你将从共享基础设施入手，比较和动手练习适用于企业和消费者场景的三种部署方案，最后了解成本和生产环境强化指南。
- 扩展部分：你将把在**基础部分**掌握的智能体部署经验，结合多智能体编排、智能体通信、向量化存储和检索等高级技术，组合为完整的模拟业务流程，包括数据处理、企业知识库、多智能体协作、业务分析和计划等。

<!-- > 📊 **更喜欢幻灯片？**
>
> 打开[简介](https://oxcp.github.io/ainotes/agenthost/module-00/)，逐步浏览研讨会内容。 -->

> [!TIP]
> 为获得更好的阅读和导航体验，请使用 [Azure 上的智能体托管研讨会指南](https://oxcp.github.io/ainotes/markdown-viewer.html?file=agenthost/README_CN.md)。

---

## 研讨会大纲

### 基础部分：
- **目标场景**：ToB 企业场景和 ToC 消费者场景，两者在隔离、扩展、身份验证和成本方面各有不同的优先级。
- **解决方案（有关详细信息，请参阅[研讨会简介](./module-00/README_CN.md)）**：
  - **解决方案 A**：Azure AI Foundry Hosted Agent（ToB 托管）— 最快捷的入门路径，提供原生状态和身份验证，以及强大的治理和安全性。
  - **解决方案 B**：AKS + agent-sandbox（ToB / ToC）— 高度可定制：满足 ToB 特有的企业技术要求，或针对 ToC 优化成本和性能。
  - **解决方案 C**：ACA 容器运行时选项（ToC / ToB）：
    - **研讨会路径**：ACA Sandboxes — 服务托管的沙盒隔离（微型 VM 边界），支持挂起/恢复。
    <!-- - **可选学习路径**：ACA Dynamic Sessions — 使用 Hyper-V 隔离的会话池，实现低延迟的临时执行。 -->
- **已实现的功能**：状态持久化、缩容到零、隔离、Entra ID 身份验证以及 AI Gateway 集成。

### 扩展部分：
- **[Module 06：多智能体业务场景](./module-06/readme_CN.md)**：将 5 个具有实际业务能力的智能体托管，结合 A2A、LangGraph、Azure HorizonDB，构建为完整的业务流程，包括数据处理、企业知识库、多智能体协作、业务分析和计划。

## 先决条件（研讨会开始前）

可以选择以下任一种方式，准备运行研讨会脚本和命令的环境：

1. **使用自己已有的环境**，例如 Linux 控制台、WSL
2. **部署控制台 VM**，如果不打算自行设置环境和工具，可以借助 [控制台 VM 模板](./az-toolbox-vm/README_CN.md) 中的模板，一键式部署一台包含研讨会执行所需工具的 控制台VM
3. **Azure Cloud Shell**

> [!tip]
> - 如果没有常用的动手操作环境，选择方式2 **部署控制台 VM** 以快速准备控制台 VM，并预装所需的工具。安装的控制台 VM 会额外产生Azure资源消耗
> - Azure Cloud Shell 已包含本研讨会大部分所需工具，但 Module 06 所需的 `aca` CLI 可能仍需单独安装。使用Azure Cloud Shell 需要注意空闲导致会话超时。会话超时将导致会话变量和临时安装的工具丢失，但已配置持久存储上的内容则可以保留。


以下是本研讨会各个练习模块所需满足的先决条件清单：

| 范围 | 要求 |
|---|---|
| 通用 / Module 01 | Linux/WSL、Bash 4+，Azure CLI 2.80.0+、有效 Azure 登录、研讨会部署所需的 26 项 ARM 操作权限、`git`、`curl`、`jq` 和 Bicep 0.48.1+。 |
| Module 02 | Azure Developer CLI（`azd`）、有效 azd 登录、`microsoft.foundry` 扩展和 Foundry User 角色。 |
| Module 03 | `kubectl`、ACR 远程生成/推送权限，以及支持 AKS Pod Sandboxing 的 Azure CLI。 |
| Module 04 | Container Apps 预览扩展和 Container Apps SandboxGroup Data Owner 角色；复用 Module 03 的 ACR/镜像。 |
| Module 06 | 复用前面模块已准备的工具，增加： `aca` CLI、ACA 认证、`openssl` 和 GNU coreutils 的 `timeout`。 |

无论使用哪种环境，均需检查并满足研讨会执行的先决条件。按下文说明运行  `check-prerequisites.sh`，检查所需工具安装状态及其他先决条件。

请登入您的操作环境，从研讨会的 GitHub 仓库中获取检查器 `check-prerequisites.sh` 到本地：

```bash
curl -fsSL https://raw.githubusercontent.com/oxcp/ainotes/main/agenthost/check-prerequisites.sh -o check-prerequisites.sh
```
> [!tip]
> 如果暂时还没有安装工具curl，请从浏览器中访问以上地址，复制 `check-prerequisites.sh` 的内容，并保存到您登录的操作环境的本地文件 `check-prerequisites.sh`。

运行检查器，获取工具安装状态及其他先决条件检查结果：

> [!tip]
> 通过浏览器复制下来的 `check-prerequisites.sh` 内容，可能需要把其中 Windows 的 CRLF (\r\n) 转成 Linux 的 LF (\n)。

```bash
sed -i 's/\r$//' check-prerequisites.sh # 只在需要把 Windows CRLF (\r\n) 转成 Linux 的 LF (\n) 时运行
chmod +x check-prerequisites.sh
bash check-prerequisites.sh
```
检查器按模块对结果进行分组，清晰标识已通过和未通过的要求，并为每个失败的检查提供修复参考链接。

输出将类似于以下内容：

输出将类似于以下内容：
> [!TIP]
> 下面的示例展示了检查器如何识别未满足的先决条件并建议后续步骤。

```text
Agent Hosting on Azure Workshop - Prerequisite Check
------
[01/19] Checking Azure CLI 2.80.0+...
[02/19] Checking active Azure login...
[03/19] Checking workshop deployment permissions...
[04/19] Checking curl installation...
[05/19] Checking jq installation...
[06/19] Checking Bicep 0.48.1+...
[07/19] Checking Azure Developer CLI installation...
[08/19] Checking active azd login...
[09/19] Checking Microsoft Foundry azd extension...
[10/19] Checking Foundry User role...
[11/19] Checking kubectl installation...
[12/19] Checking ACR remote build permissions...
[13/19] Checking Azure CLI support for AKS Pod Sandboxing...
[14/19] Checking Container Apps preview extension...
[15/19] Checking Container Apps SandboxGroup Data Owner role...
[16/19] Checking independent ACA CLI...
[17/19] Checking ACA authentication...
[18/19] Checking OpenSSL installation...
[19/19] Checking GNU timeout installation...

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
Bicep 0.48.1+                            | Pass       | Installed: 0.48.1

Module 02
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Azure Developer CLI installed            | Pass       | Installed: 1.27.0
Active azd login                         | Pass       | azd authentication is active
Microsoft Foundry azd extension          | Pass       | microsoft.foundry is installed
Foundry User role                        | Pass       | Role assignment found for the current subscription

Module 03
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
kubectl installed                        | Pass       | Installed: v1.35.0
ACR remote build permissions             | Pass       | All 4 required ACR build and push actions are allowed
Azure CLI for AKS Pod Sandboxing         | Pass       | Installed: 2.85.0

Module 04
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Container Apps preview extension         | Pass       | containerapp 1.3.0b4 (preview enabled)
SandboxGroup Data Owner role             | Pass       | Role assignment found for the current subscription

Module 06
Prerequisite                             | Result     | Details
-----------------------------------------+------------+-----------------------------------------
Independent ACA CLI                      | Pass       | aca 1.0.0-preview.5; required manifest/disk commands available
ACA authentication                       | Pass       | aca authentication is active; guest identity still needs separate configuration
OpenSSL installed                        | Pass       | OpenSSL 3.0.0
GNU timeout installed                    | Pass       | timeout (GNU coreutils) 9.4

Summary: 19 passed, 0 skipped, 0 failed
Workshop readiness: Ready to start.
Module 06: follow its guide to reuse earlier resources; this checker does not repeat resource discovery or permission checks for that module.
Preflight does not verify secrets, model/Blob calls or live Agent health. Follow the Module 06 deployment and business-flow checks.
```
> [!TIP]
> 1. 如果**所有模块的通用先决条件**和**模块 01**中没有失败的检查，脚本会报告 `Workshop readiness: Ready to start`，此时你可以开始研讨会。
> 2. 默认模式下，**Modules 02–04 或 06**的失败不阻止开始 Module 01。通用/Module 01 检查失败时默认退出码为 `1`，否则为 `0`；`--strict` 遇到**任何 Failed 或 Skipped** 都返回 `1`。未知参数返回 `2`。“Ready to start” 不代表 Module 06 部署/健康验收通过。
> 3. 在研讨会开始之前，Azure Container Registry 尚未部署，因此 `check-prerequisites.sh` 会将 **ACR 远程生成权限**检查报告为 `Skipped`。完成模块 01 后，请再次运行检查器以验证这些权限。模块 03 使用 `az acr build`。在注册表范围内分配 **Contributor** 足以执行生成和映像推送操作。
> 4. **模块 03** 和**模块 04**共享同一个 Azure Container Registry 和容器映像。因此，已部署且可访问的 ACR 是模块 03 和模块 04 的共同先决条件。
> 5. **模块 06** 需复用 **模块 03** 和**模块 04** 使用的ACR，但会上传新创建的智能体镜像。

如果“研讨会部署权限”检查发现研讨会部署所需的任何操作不被允许，检查器将列出每个缺失的 ARM 操作，如下所示：

```text
Missing 2 required ARM action(s); see the list below

Fix suggestion:
- Missing ARM action: Microsoft.Authorization/roleAssignments/write
- Missing ARM action: Microsoft.ContainerService/managedClusters/write
- Permission guidance: https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal-subscription-admin
```

---

## 如何使用本研讨会

1. 创建一个用于存储研讨会文件的本地目录（例如 `myworkshop`），然后进入该目录：

  ```bash
  mkdir myworkshop
  cd myworkshop
  ```

2. 使用稀疏签出克隆存储库，进入生成的 `ainotes` 目录，然后签出 `agenthost` 目录：

  ```bash
  git clone --depth 1 --filter=blob:none --sparse https://github.com/oxcp/ainotes/
  cd ainotes
  git sparse-checkout set --no-cone '/agenthost/'
  ```

这将下载 `agenthost` 研讨会所需的内容。

---

## 研讨会模块

| 模块 | 主题 | 时长 | 目的 |
|---|---|---|---|
| [module-00](./module-00/README_CN.md) | 简介 | 10 分钟 | 了解目标场景、智能体状态模式和三种托管解决方案。 |
| [module-01](./module-01/README_CN.md) | 核心基础设施设置 | 20 分钟 | 部署所有托管解决方案共用的 Azure 基础设施。 |
| [module-02](./module-02/README_CN.md) | 解决方案 A：Foundry Hosted Agent | 30 分钟 | 部署具有原生状态、身份验证、治理和 AI Gateway 集成的托管 Foundry 智能体。 |
| [module-03](./module-03/README_CN.md) | 解决方案 B：AKS + agent-sandbox | 40 分钟 | 在 AKS 上部署可定制的智能体运行时，具备沙盒隔离、持久状态和工作负载标识。 |
| [module-04](./module-04/README_CN.md) | 解决方案 C：ACA Sandboxes（研讨会路径） | 30 分钟 | 在 ACA Sandboxes 中部署具有微型 VM 隔离及挂起/恢复功能的智能体。<!-- ，并探索作为可选路径的 Dynamic Sessions。 --> |
| [module-05](./module-05/README_CN.md) | 总结和问答 | 5 分钟 | 比较解决方案，并查看选择指南、成本优化和生产环境强化建议。 |
| [module-06](./module-06/readme_CN.md) | 扩展练习：多智能体业务场景 | 额外安排 | 以 Product Launch Studio 为示例，复用 Modules 01/04；部署 HorizonDB 和五个 ACA Sandboxes，然后上传/处理/向量化数据并通过 Chat UI 查询。 |

> **研讨会总时长：**135 分钟。
> **动手练习（模块 01–04）：**120 分钟。
> **Module 06：多智能体业务场景**为额外扩展练习，不计入 135 分钟的核心研讨会。

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
│   ├── uiFormDefinition.json    ← 按认证方式动态显示凭据的门户表单
│   ├── cloud-init.yaml          ← 首次启动配置与统一工具验证
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
│   ├── README.md                ← 研讨会路径：ACA Sandboxes
│   ├── README_CN.md             ← 中文 ACA 沙盒指南
│   ├── sandbox.bicep            ← 研讨会路径：SandboxGroup（真正的 Sandboxes、微型 VM 边界、挂起/恢复）+ UAMI AcrPull 角色
│   ├── sandbox-deploy.sh        ← 研讨会路径：复用模块 03 映像 + SandboxGroup + 磁盘映像 + 沙盒管理
│   └── container-app.yaml       ← 旧版标准 ACA 清单（仅供参考）
├── module-05/
│   ├── README.md                ← 比较回顾、决策指南、成本技巧和生产环境清单
│   └── README_CN.md             ← 中文总结指南
└── module-06/
    ├── readme.md                ← 多智能体业务场景：完整安装、部署、上传/向量化和聊天操作指南
    ├── readme_CN.md             ← 中文多智能体业务场景指南
    ├── prompt/                 ← 原始需求/设计输入
    └── agent-src/
        ├── chat_agent/         ← Chat UI 和聊天 API
        ├── orchestrator_agent/ ← LangGraph 编排和 A2A 路由
        ├── data_processing_agent/ ← 上传、提取和向量化
        ├── rag_agent/          ← 向量检索
        ├── sql_agent/          ← 结构化查询
        ├── sample-data/        ← 合成演示数据集
        ├── deploy/             ← HorizonDB Bash/Bicep、ACR 远程生成和 ACA CLI 部署
        └── docs/               ← 八份详细设计/运维指南及其 _CN 对应版本

```

<!--
│   ├── README.md                ← 研讨会路径：ACA Sandboxes；可选路径：Dynamic Sessions
│   ├── dynamic-session-deploy.sh← 可选路径：会话池部署（自定义容器）
│   ├── dynamic-session-invoke.sh← 可选路径：会话池终结点的最小调用示例
│   ├── dynamic-sessions.md       ← 可选的 Dynamic Sessions 学习指南
-->

---
