# Azure 上的智能体托管研讨会

> 🌐 语言 / Language: [English](readme.md) | **中文**

## 研讨会简介

本研讨会将带你踏上一段实用的 Azure 智能体托管之旅：
- 基础部分：你将从共享基础设施入手，比较和动手练习适用于企业和消费者场景的三种部署方案，最后了解成本和生产环境强化指南。
- 扩展部分：你将把在**基础部分**掌握的智能体部署经验，结合多智能体编排、智能体通信、向量化存储和检索等技术练习，实现完整的模拟业务流程。

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
- **[Module 06：多智能体业务场景](./module-06/readme_CN.md)**：同时托管 5 个智能体，并使用 A2A 智能体间通信和 LangGraph 编排协作五个智能体，实现模拟的业务场景，包括数据处理、企业知识库、业务分析和计划等。
- 支持选择 **Azure HorizonDB**（默认）或 **Azure Database for PostgreSQL Flexible Server** 作为结构化数据与向量的存储和检索。

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
> 2. 默认模式下，**Modules 02–04 或 06**的失败不阻止开始 Module 01。
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
| [module-01](./module-01/README_CN.md) | 核心基础设施设置 | 30 分钟 | 部署所有托管解决方案共用的 Azure 基础设施。 |
| [module-02](./module-02/README_CN.md) | 解决方案 A：Foundry Hosted Agent | 30 分钟 | 部署具有原生状态、身份验证、治理和 AI Gateway 集成的托管 Foundry 智能体。 |
| [module-03](./module-03/README_CN.md) | 解决方案 B：AKS + agent-sandbox | 40 分钟 | 在 AKS 上部署可定制的智能体运行时，具备沙盒隔离、持久状态和工作负载标识。 |
| [module-04](./module-04/README_CN.md) | 解决方案 C：ACA Sandboxes（研讨会路径） | 30 分钟 | 在 ACA Sandboxes 中部署具有微型 VM 隔离及挂起/恢复功能的智能体。<!-- ，并探索作为可选路径的 Dynamic Sessions。 --> |
| [module-05](./module-05/README_CN.md) | 总结和问答 | 5 分钟 | 比较解决方案，并查看选择指南、成本优化和生产环境强化建议。 |
| [module-06](./module-06/readme_CN.md) | 扩展练习：多智能体业务场景 | 60 分钟 | 模拟业务场景，部署 5个 智能体，通过多智能体间的编排和协作，处理上传的业务数据，并据此做智能分析和计划。 |

> [!NOTE]
> - **核心研讨会（模块 00–05）**：145 分钟，包含 **动手练习（模块 01–04）**：130 分钟。
> - **Module 06 多智能体业务场景**：建议额外安排 60 分钟。
> - **包含 Module 06 的总时长**：205 分钟（3 小时 25 分钟）。

---

## 研讨会结构

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
│   ├── .gitattributes          ← 文件属性与换行规则
│   └── scripts/
│       └── verify-tools.sh      ← 验证工具版本和用户范围扩展
├── pic/                         ← 研讨会截图，包括 toolbox-vm-deployment.png
├── module-00/
│   ├── .gitignore               ← 排除旧 index.html、slides/ 及 *notused* 文件
│   ├── README.md                ← 体系结构决策、场景和解决方案比较
│   ├── README_CN.md             ← 中文简介指南
│   ├── design.html              ← 交互式研讨会设计幻灯片
│   ├── design_CN.html           ← 中文设计幻灯片，含 60 分钟 Module-06 扩展部分
│   ├── timer-en.html            ← 英文研讨会计时器
│   └── timer.html               ← 中文研讨会计时器
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
│       ├── __pycache__/         ← 当前已上传的 Python 字节码缓存
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
│       │   ├── __pycache__/     ← 当前已上传的 Python 字节码缓存
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
    ├── deploy.sh                ← 自动前置检查后直接部署、通用配置发现及阶段选择
    ├── deploy-storage.sh        ← 仅在 Module-01 已有存储中增量 ARM 预配私有 data 容器
    ├── deploy-models.sh         ← 部署 embedding 并扩展已有 APIM 路由；已有授权保持不变
    ├── deploy-database.sh       ← 数据库验证/预配及 HorizonDB 配置/管理员辅助函数
    ├── build-images.sh          ← 五个远程 ACR 构建，共用 agent-src 构建上下文
    ├── deploy-aca.sh            ← 五个沙箱的配置、挂载、迁移、启动与就绪检查
    ├── cleanup.sh               ← 清理 Module-06 专属资源和生成配置，保留 Modules 01–04 共享资源
    ├── bicep/
    │   ├── storage.bicep        ← 私有 data 容器；existing 账户/Blob 服务
    │   ├── embedding.bicep      ← embedding 模型及 APIM 操作/后端/策略；不修改 RBAC
    │   ├── database.bicep       ← 统一提供程序选择；不重复创建共享资源
    │   ├── horizondb.bicep      ← HorizonDB 后端
    │   └── postgresql.bicep     ← PostgreSQL Flexible Server 后端
    ├── common/
    │   ├── aca-config.jq        ← 共享受保护五角色配置验证
    │   ├── cleanup-aca.jq       ← 沙箱、磁盘、快照和卷的清理归属及引用校验
    │   ├── cleanup-ownership.sh ← embedding/APIM 子资源归属记录与清理安全校验
    │   └── resolve-identity.sh  ← 为各阶段解析 Module-01 UAMI 标识
    ├── sample-data/             ← 实际业务样本，不进入 Agent 镜像
    │   ├── 01_capgemini_consumer_trends_2025-pages-*.pdf ← Capgemini 报告，5 个分片
    │   ├── 02_ryder_ecommerce_consumer_study_2025-pages-*.pdf ← Ryder 报告，5 个分片
    │   ├── 03_customer_reviews-rows-*.csv ← 客户评论，21 个分片
    │   ├── 04_financial_sample-rows-000001-000700.csv ← 财务数据，700 行
    │   ├── manifest.json        ← 分片与原文件、页码/行号的对应清单；不是上传输入
    │   ├── split_samples.py     ← 可选分片工具；依赖已安装的 agent-src 包
    │   └── raw/                 ← 四份未拆分原件；不要与其分片在同一工作区重复上传
    └── agent-src/               ← 五个 Agent 共用的镜像构建上下文
        ├── README.md            ← 英文源码与运行说明
        ├── readme_CN.md         ← 中文源码与运行说明
        ├── pyproject.toml       ← Python 依赖、打包和开发工具配置
        ├── MANIFEST.in          ← Python 源码分发包的资源包含/排除规则
        ├── .dockerignore       ← Docker 构建上下文排除规则
        ├── .env.example        ← 本地开发环境变量示例；不是沙箱部署配置
        ├── .gitignore          ← 排除本地环境、凭据和生成文件
        ├── .gitattributes      ← 源码文件属性与换行规则
        ├── compose.yaml        ← 可选本地开发 Compose 配置
        ├── compose.agents.yaml ← 可选五 Agent 本地 Compose 配置
        ├── chat_agent/         ← Chat UI/API、Dockerfile 和中英文 README；static/ 为前端资源
        ├── orchestrator_agent/ ← LangGraph 编排、A2A 路由、Dockerfile 和中英文 README
        ├── data_processing_agent/ ← 数据提取/向量化、Dockerfile 和中英文 README
        ├── rag_agent/          ← 向量检索、Dockerfile 和中英文 README
        ├── sql_agent/          ← 只读结构化查询、Dockerfile 和中英文 README
        ├── docs/               ← 八组中英文文档，共 16 个 Markdown 文件
        │   ├── architecture*.md ← 架构与组件职责
        │   ├── cli-deployment*.md ← 统一 CLI 部署与配置
        │   ├── data-processing*.md ← 上传、摄取与向量化
        │   ├── implementation-report*.md ← 历史实现与验收报告
        │   ├── orchestration*.md ← LangGraph 规划、A2A 协作与审核
        │   ├── sandbox-deployment*.md ← AKS / ACA 部署路径
        │   ├── security*.md     ← 身份认证、数据边界与运维
        │   └── workshop-guide*.md ← 研讨会数据与演示指南
        ├── shared/             ← Agent 共用的配置、A2A、数据库、模型、存储和图表代码
        └── migrations/
            ├── __init__.py
            └── 001_initial.sql ← 初始 schema；由 Orchestrator 沙箱中的迁移命令执行

```
