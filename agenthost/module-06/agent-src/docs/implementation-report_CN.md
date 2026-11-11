# 模块 06 实现与验收报告

> 🌐 语言 / Language: [English](implementation-report.md) | **中文**

> **历史快照，不是当前部署操作说明，也不是最新验收结果。**
> 下文的状态、测试数量、阻塞项及使用现在时态的描述，均指这里记录的实现阶段。
> 保留这些内容用于追溯，不应将其视为最新源码或云端部署状态。
> 特别是，浏览器/工作区密钥及由密钥派生的所有者已在后续版本移除。
> 当前 Bash 主路径采用 Entra 数据库认证、共享免密工作区和 A2A 对等认证；
> 打包的唯一 SQL 脚本初始化不含所有者列的结构。
> 当前行为请参阅[模块操作指南](../../readme_CN.md)、[CLI 部署指南](cli-deployment_CN.md)及
> [架构](architecture_CN.md)。应针对具体源码版本、镜像摘要、提供程序和部署重新记录验收，
> 不要沿用下文的历史通过数量。
> 下文的合成数据和固定 SQL 总额仅属于当时的历史测试。
> 当前 workshop 使用实际的[模块级上传分片](../../sample-data/)，按实际上传文件核对结果，
> 不使用 `agent-src/sample-data`。

**记录时的状态：分布式实现和本地验收通过；镜像及真实云端验收当时尚未完成。**
此前的 Windows asyncio 启动和 Docker 引擎阻塞问题已解决。
Docker 29.9.2（Linux）成功运行了本地 PostgreSQL/vector 测试。
历史上的本地镜像构建在下载依赖时遇到来自 `files.pythonhosted.org` 的 `SSLV3_ALERT_HANDSHAKE_FAILURE`。
构建入口现在针对已有注册表使用 ACR Tasks 快速构建（`az acr build`），
沿用 Module-03 实际构建、Module-04 复用镜像的流程。
本地镜像构建不再是研讨会路径。尚未提交真实 ACR 运行，不宣称云端构建成功。
不宣称已完成云部署或获得真实云端模型/数据服务结果。

## 实现清单

数据库后端现支持 `DB_PROVIDER=horizondb`（默认）或 `postgresql`（Azure PostgreSQL Flexible Server）。
所有配置改为通用 `DB_*` / `db_*`，共用一个 psycopg 仓储、SQL 和迁移，默认 `postgres` 数据库。
新增通用部署入口和 PG17 Flexible Server 模板，保留 HorizonDB 兼容入口，统一无密钥资源清单、
vector 允许列表、TLS 和显式防火墙规则；失败不回退后端。业务、A2A 和模型行为未改动。
本次验证仍为本地/离线验证，未创建任何 Azure 数据库或计费资源。

| # | 要求的报告项 | 结果 |
|---|---|---|
| 1 | Module 01 调研 | 通过配置复用 Foundry 模型/项目、APIM 和托管身份；未修改 |
| 2 | Module 03 调研 | 纯 HTML/CSS/JS 聊天和 Responses 集成；改编 UI，移除 Chat 的直接模型调用 |
| 3 | 架构 | 五个独立 Agent 服务、A2A 发现/协作、Orchestrator 内部使用 LangGraph |
| 4 | 目录结构 | 五个 Agent 包及 shared、migrations、deploy、tests、docs 和 sample-data |
| 5 | 新增文件 | A2A 传输、远程代理、工作 Agent 入口、五个 Dockerfile、Compose 拓扑、AKS 渲染器、真实 ACA SDK 部署辅助程序和来宾启动器、镜像脚本、测试及沙箱指南 |
| 6 | 修改文件 | 两份请求的提示文件；Module-06 配置、Orchestrator 注入、Chat 组装、依赖清单、打包及相关文档 |
| 7 | 边界 | Agent 实现仍位于 Module-06/agent-src，两份请求的提示文件位于 Module-06；根目录 Markdown Viewer 及其导航测试也包含 Module-06 |
| 8 | 图 | 接收、规划、DIRECT 或远程工作 Agent、汇总、综合、审核、一次修订、明确错误及响应 |
| 9 | Blob | Chat 存储原始文件；FileRef 跨 A2A 传输；Processing 直接读取私有 Blob；仅开发时使用本地共享目录 |
| 10 | HorizonDB | 仓储和打包迁移通过真实本地 PostgreSQL 17/pgvector 测试；Azure HorizonDB 本身仍未验证 |
| 11 | 处理 | PDF/DOCX/TXT/MD/CSV/XLSX/JSON、有类型关系型行、token 有界且 Unicode 安全的分块、关联评论向量 |
| 12 | RAG | 工作区/元数据过滤、余弦阈值、最多五个带来源结果、明确提示证据不足 |
| 13 | SQL | 感知结构的生成、AST 门控、受限只读查询、工作区重写、精确结果；传输保留大整数 |
| 14 | DIRECT | 通过图、A2A 五进程 API 和使用显式模型夹具的浏览器验证 |
| 15 | RAG | 通过远程工作 Agent 和上传合成报告的浏览器验证 |
| 16 | SQL | 通过远程工作 Agent 和浏览器验证；样本 France=4000、Germany=3300 |
| 17 | HYBRID | 并行事件屏障测试通过；五进程和浏览器综合路径通过；终止 SQL 对等服务后产生明确部分结果 |
| 18 | 进度 | Processing 的 A2A 任务状态 SSE 注入运行事件；浏览器轮询 Chat，Chat 经 A2A 轮询 Orchestrator |
| 19 | 通用模型 | Foundry Responses 适配器保持真实生产实现；实际云端调用未验证 |
| 20 | 嵌入 | 保留 Foundry 批处理/维度验证；真实云端调用未验证 |
| 21 | 本地设置 | venv、可编辑开发安装、.env、PostgreSQL、迁移、五个原生进程或 Compose |
| 22 | Azure 配置 | 五个沙箱 URL、对等/浏览器密钥、私有 Blob/HorizonDB、模型端点、运行时身份和网络 |
| 23 | 迁移 | `python -m shared.database`；要求专用数据库和稳定的向量维度 |
| 24 | 启动 | 各 Agent 的 `app:create_app` 在自己的端口/进程运行；见 README 表格 |
| 25 | 测试命令 | 完整 pytest、Node UI 测试、Ruff、mypy、compileall、包构建和部署产物检查 |
| 26 | 已执行测试 | 所有本地单元/API/图/A2A/进程测试；实际浏览器上传和四种模式 |
| 27 | 测试结果 | 启用真实 PostgreSQL 后 80 项 Python 通过、0 项跳过；此前验收中 3 项 Node UI 通过；没有取消选择异步测试 |
| 28 | 静态/构建 | Ruff、格式、mypy、Python/JS 语法及 wheel/sdist 检查；历史本地构建失败；ACR 镜像执行仍未验证 |
| 29 | 限制 | 单 Orchestrator 调度器、无持久化的运行中恢复、研讨会共享身份/密钥、无 RLS/OCR/自动保留清理 |
| 30 | 后续步骤 | 使用获准的已有注册表运行 ACR 构建包装脚本，验证五个已发布镜像，配置云资源并执行真实 AKS/ACA 验收 |
| 31 | A2A | 官方 SDK 1.3.0、协议 1.0 JSON-RPC/SSE、经过认证的卡片、固定端点/角色/技能、类型化消息、失败任务和有界临时任务历史 |
| 32 | 镜像/沙箱 | 五个 Dockerfile 和启动模块；AKS Sandbox/Kata 渲染器；对真实 SDK 签名测试的 ACA SDK 0.1.0b4 部署辅助程序，以及 Portal 替代路径 |

详细结构、环境变量和命令见 [README](../readme_CN.md)。
沙箱/镜像细节见[沙箱部署](sandbox-deployment_CN.md)。

## Bash/Bicep/ACA CLI 部署路径

- 新增 [HorizonDB Bicep](../../bicep/horizondb.bicep) 和自动执行 ARM 验证后直接部署的 Bash 包装脚本。
  复用 Module-01 已有资源组/区域，创建 PostgreSQL 17 HorizonDB 集群和 vector 参数组，
  默认采用研讨会公网 IPv4 访问（`0.0.0.0` - `255.255.255.255`），接受显式受限防火墙范围，
  并通过安全参数文件传递密码。公网开放是研讨会的有意设置，仍要求 TLS/认证。
- 新增 [Bash ACA 部署](../../deploy-aca.sh)，保留 SDK 替代路径。
  复用 Module-04 的组，使用已有拉取身份导入五个 ACR 镜像，创建五个 Sandbox，
  安全分发发现的 URL/配置，可选运行应用迁移，检查数据库/结构访问，
  等待五个健康/卡片探测并检查只读 Chat A2A 调用。
- Bicep MCP 编译器 **0.48.1**：编译成功，**零诊断**。
  已安装的 Azure CLI Bicep **0.44.1** 也能编译，但提示缺少预览类型；
  资源属性验证使用较新的结构/编译器。
- 初次部署路径运行 `tests/deploy-shell.test.sh`：使用真实 **ACA CLI 1.0.0-preview.5 离线清单验证**，
  **通过，退出码 0**。Azure/HTTP 操作为替身。
  覆盖参数/配置拒绝、显式上下文和区域复用、命令参数/输出无密钥、受保护上传顺序、
  五角色拓扑、重试至就绪、精确失败阶段、部分资源清单、错误卡片、
  A2A 调用失败、来宾非零退出码和有界超时。
- 已有部署/启动器/SDK 契约测试：**7 项通过，退出码 0**。
  实际 A2A SDK 卡片序列化与 Bash 就绪谓词一致。
  wheel/sdist 包含 shell 脚本、Bicep 和 jq 验证器；已检查文档链接和 shell LF 换行。
- 未执行 HorizonDB 部署、镜像导入、计费 ACR 构建或真实五 Sandbox 验证。
  CLI 帮助/结构检查和替身测试**不是**云端验收。
  来宾身份、网络出站、预览可用性和实际模型/Blob/工作 Agent 流程仍需外部验收。
- 可执行步骤、防火墙/身份前提、数据库初始化、状态、超时和清理见 [CLI 操作指南](cli-deployment_CN.md)。
  未修改 Module-01/04 文件。
- 部署参数覆盖环境变量；共享默认值与 Modules 01/04 一致（`IMAGE_TAG=latest`、
  `AUTO_SUSPEND_MINS=15`、已有资源组/区域/资源命名）。
  英文 README 现已有等价[中文版](../readme_CN.md)；根目录 Markdown Viewer 提供 Module-06 及 Agent/操作指南入口。

后续生命周期修正：上面记录的初始 `15` 分钟默认值已改为 `AUTO_SUSPEND_MINS=0`（禁用），
用于持续协作的 Agent。Manual 激活端口不会唤醒已挂起的工作 Agent。
可选 SDK 部署器也禁用自动挂起；这样提高可用性，但会产生闲置计算费用。

### 公网访问、环境变量与导航后续验证

- 扩展 Bash 部署测试：**通过，退出码 0**。
  覆盖精确公网 IPv4 范围及警告、环境变量/文件密码优先级、上下文/资源命名、
  纯环境变量部署、规格、挂起和显式参数覆盖。
  云端操作使用替身，本次后续验证未重跑可选真实 ACA CLI 验证器。
  普通失败场景与专门超时场景使用不同超时预算；后者断言退出码 **124**。
- Bash 和 PowerShell ACR 构建器测试：**通过，退出码 0**，包括 `latest`、环境标签、
  显式覆盖和失败行为。合并后的 Compose 配置在默认和覆盖标签下均正确解析五个镜像；未启动容器。
- Bicep **0.48.1** 编译：**零诊断**；已检查编译后的防火墙默认值为
  `0.0.0.0` 和 `255.255.255.255`。
- 在仓库根目录运行 `node --test tests/markdown-viewer.test.cjs`：
  **5 项通过，退出码 0**，覆盖文件名精确大小写、双语、十个 Module-06 资源链接、
  当前项选择、无配对文档和其他模块导航。
- 真实浏览器检查通过：中英文切换、两张 Mermaid 图、中文 RAG 说明，
  以及当时尚无译文的 CLI 指南不显示不存在的语言切换。
- 已比较两份 README：标题结构一致、**8 个代码块**、**35 行表格**和环境变量标识符；
  检查相关文档链接和 Bash LF 换行。wheel/sdist 构建通过，
  sdist 包含两份 README，部署资源已打包。
- 这些是本地/离线检查，不是 HorizonDB 或五 Sandbox 云端部署。

## 本地验收证据

- ACR 构建路径更新：Bash 和 PowerShell 包装脚本均通过 Azure CLI 替身测试（退出码 0），
  覆盖五个远程构建、默认/自定义标签、相对 Dockerfile 路径、含空格源码路径、
  无效参数、移除的 push 参数和快速失败行为。未提交真实 ACR 构建。
  Compose 配置检查确认五个含注册表地址的镜像，没有本地 build 定义；
  缺少 `ACR_LOGIN_SERVER` 时明确失败。七项部署测试通过。
  源码包检查包含两个包装脚本及回归脚本，shell 文件保持 LF 换行。
  已检查五组 Agent README 中英文配对和 225 个相对文档链接。
- 策略调整后的基线：**61 项通过、1 项跳过**；此前异步/API 启动挂起不再出现。
- 安装 Sandbox SDK extra 后此前扩展套件：**79 项通过、1 项跳过**。
- Docker 重试：使用 `STUDIO_TEST_POSTGRES=1`，以及随机环回端口上的隔离
  `pgvector/pgvector:pg17` 容器，**80 项通过、0 项跳过**，退出码 0；没有取消选择测试。
  真实检查覆盖迁移、摄取、向量检索、工作区隔离、精确 SQL 聚合、重复摄取、
  持久化运行查询/隔离、数据库强制只读事务，以及查询超时后成功复用连接池。
  临时容器和卷已移除。
- 历史本地五镜像构建脚本使用 `-Registry studio-local -Tag acceptance` 重试两次，
  两次都在安装第一个镜像构建依赖时返回退出码 1；没有任何 Agent 镜像完成。
  独立基础镜像 HTTPS 探测确认 PyPI 索引和 tokenizer 存储返回 HTTP 200，
  而 `files.pythonhosted.org` TLS 握手失败。未禁用证书验证。
- 五个独立操作系统进程绑定不同环回端口，使用官方 A2A JSON-RPC/SSE：
  - 五个卡片均经过认证发现；
  - 浏览器 API -> Chat -> 远程 Orchestrator -> 远程 Processing/RAG/SQL；
  - 实际文件上传到本地适配器，经 FileRef 处理；
  - DIRECT/RAG/SQL/HYBRID、SQL 总计和引用；
  - 来源/数据集列表；
  - 仅终止测试 SQL 进程，再验证 HYBRID 部分状态和 PEER_UNAVAILABLE。
- 并行证据：事件屏障测试要求两个远程工作请求均已进入后，任意一个才可完成。
- 对抗场景：伪造卡片端点/角色/技能/版本、错误对等凭据、未知所有者、
  跨工作区工作 Agent 访问、不支持的操作、格式错误输入、缺少数据集和对等服务超时。
- 大整数回归：A2A 往返保留 `9007199254740993`，避免 protobuf 双精度损失。
- ACA 适配器测试验证已安装 SDK 签名、五个独立磁盘/沙箱操作、HTTPS 端口、
  0600 配置下发、逐对等 URL、显式 apply 门控和不含密钥的失败资源清单。
  来宾启动器等待原子配置、降低 Linux 权限并 exec 指定 Agent。
  这些是模拟 SDK 调用，不是真实 Azure 资源部署。
- 对五进程夹具的集成浏览器检查：
  - 创建工作区，上传合成 Markdown 和财务 CSV；
  - 观察实际提取/嵌入/存储进度；
  - 无 UI 错误地完成 DIRECT/RAG/SQL/HYBRID；
  - 检查 SQL 证据并验证 France 4000 / Germany 3300；
  - 重新加载并连接：对话历史恢复，访问密钥未持久化。
- Node UI 测试：安全文本渲染、真实事件显示和明确失败/重试处理通过。

浏览器测试最初尝试用 `innerText` 检查隐藏的 details 元素；
将断言改为 `textContent` 后验证了精确总计。这是测试检查方式问题，不是 SQL 被修改。

**重要：** 五进程/浏览器测试使用显式仅测试模型和 SQLite 仓储；
可选 PostgreSQL 集成测试使用真实仓储和真实 PostgreSQL/vector，但不调用模型。
生产入口没有夹具开关，也没有静默的进程内/SQLite 回退。
本地成功不代表 Foundry 质量、HorizonDB 向量兼容性、Azure Blob 凭据、
容器启动、Kata 隔离或 ACA 生命周期已经验证。

## 验证命令

```sh
python -m pytest -q -p no:cacheprovider
node --test tests/ui.test.cjs
node --check chat_agent/static/app.js
python -m ruff check .
python -m ruff format --check .
python -m mypy shared data_processing_agent rag_agent sql_agent orchestrator_agent chat_agent deploy
python -m compileall -q shared chat_agent orchestrator_agent data_processing_agent rag_agent sql_agent deploy
python -m build --no-isolation
```

AKS 产物测试断言五个真实 Sandbox CRD、Kata 运行时、非 root 镜像命令、不同服务名称、
密钥引用和 NetworkPolicy，不能替代目标集群上的 `kubectl apply --dry-run=server`。
镜像构建 PowerShell 脚本解析成功。
wheel/sdist 资源检查覆盖 SQL 迁移、UI、逐 Agent Dockerfile 和部署说明。
Mypy 在 Windows 宿主机和 Linux 目标上都通过全部 30 个运行时/部署 Python 文件。
Compose 合并后的六服务配置无需运行 Docker 引擎即可验证。

## 剩余验收阻塞项（不要签署完整云端验收通过）

| 检查 | 实际观察 | 明确后续步骤 |
|---|---|---|
| ACR 镜像构建 | 脚本现在提交云构建并发布到已有 ACR；尚未执行真实 ACR 构建。此前本地 TLS 失败是历史记录，不能证明 ACR 网络问题。 | 登录获准订阅，使用已有 ACR 资源名运行五镜像包装脚本，记录运行结果/摘要，再验证容器执行 |
| Azure HorizonDB | 本地 PostgreSQL 17/pgvector 测试通过，实际 Azure 端点未测试 | 使用专用且获准的 Azure 测试数据库和必需 TLS 重复 STUDIO_TEST_POSTGRES=1；绝不使用共享生产数据库 |
| Foundry 和 Azure Blob | 本次验收未配置实际端点/部署/运行时凭据 | 提供预期测试配置，针对它运行上传及模型/嵌入路径 |
| AKS Sandbox | 清单已生成/测试但未应用；尚无获准部署的目标集群/命名空间 | 验证 CRD/Kata/身份/网络前提，dry-run 后应用，再重复浏览器流程 |
| ACA Sandbox | 已提供 SDK 辅助程序和 Portal 替代路径；未创建沙箱 | 配置已有 SandboxGroup 和凭据，验证配置，显式使用 --apply 运行 Python SDK 辅助程序，再重复完整流程 |

最初的包查找未包含预发布版本。后续 `pip index versions --pre` 找到
`azure-containerapps-sandbox==0.1.0b4`，已将其声明为可选依赖、安装、检查并用于真实部署实现。
此前 SDK 可用性限制已解决。

初始实现阶段的历史说明：成功记录了已有 Git 状态。
整个 Module-06 目录当时已是未跟踪状态，因此仅 `git diff` 不能列出其全部变更。
该阶段任务未修改 Module-06 之外的已跟踪文件，已有无关未跟踪目录/文件保持不变。
未提交 commit，也未执行云端部署。
当时根 README 没有中文配对，后续已添加源码及模块根目录的双语 README。
五组逐 Agent 中英文 README 已同步 ACR 构建命令。
