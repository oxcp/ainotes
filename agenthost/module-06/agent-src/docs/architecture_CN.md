# 架构

> 🌐 语言 / Language: [English](architecture.md) | **中文**

整合后的模块概述、部署和演示步骤请从[模块 6：多智能体业务场景操作指南](../../readme_CN.md)开始。
本页说明系统整体架构；各 Agent 的实现详见
[Chat](../chat_agent/README_CN.md)、[Orchestrator](../orchestrator_agent/README_CN.md)、
[Data Processing](../data_processing_agent/README_CN.md)、[RAG](../rag_agent/README_CN.md) 和
[SQL](../sql_agent/README_CN.md) 的 README。

Python 包名使用下划线而不是建议的连字符，以便直接导入。
每个工作 Agent 通过标准 A2A 1.0 暴露类型化操作，不依赖其他工作 Agent。
Chat API 只依赖 Orchestrator 门面和共享的依赖组装入口，不直接调用模型、工作 Agent 或数据库仓储。
生产环境的 Chat 创建远程 Orchestrator 客户端和 Blob 适配器；
生产环境的 Orchestrator 创建远程 Processing/RAG/SQL 客户端，不创建本地工作 Agent。

## 边界

- 体验层：Chat 的 FastAPI 和浏览器 UI 在独立沙箱中运行，浏览器不持有模型凭据。
- 控制平面：独立的 LangGraph Orchestrator 沙箱，检查工作区是否存在并启动受限的后台运行。
- 工作 Agent：Data Processing、RAG 和 SQL 的类型化结果由 Pydantic 验证。
- 数据平面：私有 Blob 原始文件；HorizonDB / Azure PostgreSQL Flexible Server 存储元数据、关系型表和向量。

`DB_PROVIDER=horizondb`（默认）或 `postgresql` 选择数据库资源；一个共享 psycopg 仓储使用
通用 `DB_*` 配置和相同迁移，默认 `postgres` 数据库，不改变 Agent、A2A 或模型逻辑。
- 模型：通过已有 Module-01 APIM 调用 Foundry OpenAI v1 Responses 和 Embeddings。
  Module-06 增加 embeddings 操作/后端；云端摄取和查询绝不回退到账户直连端点。

UI/CSS 和消息流程改编自 Module-03 的 `app/portal.html`：深色主题、用户消息右对齐、
回答左对齐、Enter 发送，以及等待期间禁用控件。
原有标准库 HTTP 服务器和直接模型调用被 FastAPI 和 Orchestrator 替代，Module-03 未修改。

Module-01 提供 Foundry 账户/项目、通用模型部署，以及带 UAMI 的 APIM AI 网关。
其默认值包括项目 `maf-agent-prj` 和模型 `gpt-5.4-mini`；
本模块要求通过环境变量提供实际部署名称，而不是将它们硬编码。
Module-06 `models` 阶段部署账户模型和 APIM embedding 子资源，不修改 Responses、父资源或 IAM。
操作在继承认证之前验证 Agent UAMI `oid` 与 `ai.azure.com` 受众，再使用 APIM 已有系统身份
以 `ai.azure.com` 后端认证调用账户 OpenAI 端点。已附加 UAMI 不会被选为后端身份。
仅可选本地流程可显式配置直连端点/scope。

本地环境：Compose 中的 PostgreSQL 17 + pgvector、文件系统原始文件和真实 Foundry 模型。
测试显式注入 SQLite 仓储和确定性模型替身，生产应用无法选择这些测试替身。
Azure 环境：所选 HorizonDB/PostgreSQL 后端、使用 DefaultAzureCredential 的 Blob SDK，
以及通过 Entra 凭据认证的 Foundry 请求；令牌缓存与刷新由凭据实现管理。
五个服务都拥有独立镜像和入口。AKS Sandbox 使用 Kata 隔离；
ACA 使用 SandboxGroup 磁盘镜像和独立 micro-VM。参见[沙箱部署](sandbox-deployment_CN.md)。

## 发现与通信

官方 A2A SDK 提供经过认证的 Agent Card 和 JSON-RPC/SSE 端点。
对等服务基础 URL 来自部署配置，Bash 主路径会填入实际沙箱入口 URL。
首次调用对等服务时获取并校验卡片，然后缓存客户端。
发现过程验证角色名称、技能、流式支持、协议 1.0 和精确端点，不会搜索任意新 Agent。
卡片不得将凭据重定向到其他地址。A2A Data Parts 使用由应用管理版本的 Studio JSON 字符串信封，
避免 protobuf 双精度转换破坏 SQL 整数精度。
工作 Agent 输出成为任务产物，进度成为任务状态更新，失败成为带安全结构化错误的失败任务。
A2A_API_KEY 独立于工作区数据，用于对等认证。
研讨会使用共享工作区和共享对等密钥，不使用跨组织身份联合。
云端工作 Agent 直接读取 Blob，不读取共享宿主机路径。
独立进程测试使用真实 HTTP/SSE 和共享测试存储，但不能证明 micro-VM 隔离或云服务连通性。

浏览器 API 免密：任何持有 Chat URL 的人均可访问该部署的工作区和数据。
每个工作区 API 均验证工作区是否存在。
工作 Agent 仓储包含工作区谓词；生成的 SQL 会重写，使每张获准的物理表成为按工作区过滤的子查询。
这是单操作人员的研讨会授权模型，不是生产级多用户身份体系。

## 配置与初始化

Bash 主路径从 Module-01 资源生成公共设置，或读取显式指定的 `ACA_COMMON` 输入，
再合并数据库/模型/身份输出和对等密钥，生成包含五个角色的 `aca-config.json`。
部署时为每个沙箱取出对应角色的配置、补入实际 URL，并交付受保护的
`/app/.local/studio-runtime.json`。`shared.sandbox_bootstrap` 在启动 Agent 前将其加载为进程环境变量，
由 `shared.config.Settings` 校验。`.env.example` 是参考模板，不是云端运行配置输入；
本地开发仍支持 `.env`。

运行配置 JSON 不是 Agent Card：它包含私有配置和对等密钥。卡片根据代码定义的角色技能及
`A2A_PUBLIC_URL` 生成，公布 `/a2a` 端点和认证方式，不包含密钥值。
指定 `--migrate` 时，Bash 脚本会在激活服务前，仅在 Orchestrator 沙箱中执行一次共享初始化代码。
[001_initial.sql](../migrations/001_initial.sql) 创建不含工作区密钥/所有者列的当前结构，
不会升级已有的旧版表定义。
