# Chat Agent：浏览器入口

[English](README.md) | [模块概览](../readme_CN.md) | [Orchestrator](../orchestrator_agent/README_CN.md)

## 1. 职责与设计

Chat 是 Product Launch Studio 面向浏览器的服务。它提供 UI、校验浏览器请求、保存上传原件，
并通过 A2A 将业务操作转发给 Orchestrator。它**不直接调用 LLM 或 Embedding 模型，不连接
PostgreSQL，不运行 LangGraph，也不创建本地 Worker**。这里的 Agent 指服务角色，不代表自主模型/工具循环。

生产环境的组合是 `FastAPI -> RemoteOrchestrator -> PeerClient`，另有处理上传的 `BlobStore`。
FastAPI 的 lifespan 管理代理对象，并在关闭时释放其 HTTP/存储客户端。

## 2. 代码阅读指南

| 文件 / 符号 | 阅读重点 |
|---|---|
| [app.py](app.py)：`create_app()` | 应用工厂、生命周期、浏览器路由、错误、静态文件和可选的 Chat A2A 入口 |
| [app.py](app.py)：`security()` | POST 频率/大小检查和响应安全头 |
| [shared/bootstrap.py](../shared/bootstrap.py)：`build_service()` | 只创建 `RemoteOrchestrator(config, BlobStore(config))` |
| [shared/remote.py](../shared/remote.py)：`RemoteOrchestrator` | 将浏览器操作转换成经 A2A 传输的类型化 Studio 操作 |
| [shared/storage.py](../shared/storage.py)：`BlobStore.upload()` | 校验文件名/MIME/大小/压缩包结构，保存原件并返回含校验和的 `FileRef` |
| [static/app.js](static/app.js) | `api()` 发送免密浏览器请求；`monitor()` 轮询运行；`renderMarkdown()` 安全显示文本 |
| [static/charts.js](static/charts.js) | 验证并使用本地 SVG/文本节点渲染聊天内柱状图、折线图、饼图和数值对比表 |
| [static/index.html](static/index.html)、[static/style.css](static/style.css) | UI 控件与样式 |
| [Dockerfile](Dockerfile) | 镜像构建与仅启动 Chat 的命令 |

## 3. 执行路径

### 提问

```text
Browser: POST /api/workspaces/{workspace_id}/chat
  -> security(): enforce request limits
  -> RemoteOrchestrator.start()
  -> A2A operation "chat" on Orchestrator
  <- HTTP 202 with run_id
Browser: GET /api/workspaces/{workspace_id}/runs/{run_id}
  -> A2A operation "run"
  <- progress, answer, evidence, SQL, review and terminal status
```

[shared/contracts.py](../shared/contracts.py) 中的 `Question` 包含 `conversation_id`、`message`、
`recent_context` 和可选的检索 `filters`。运行期间，浏览器每秒轮询一次，轮询期限约为 11 分钟。
浏览器进度使用轮询，**不是浏览器 SSE**；服务之间的 A2A 使用 JSON-RPC/SSE。

### 带 Agent 标识的进度

蓝色进度行根据服务端事件已有的 `stage` 标识添加负责的 Agent 前缀，而不是从消息文字猜测。
任务转交与实际执行分开标注，例如：

```text
[Chat Agent → Orchestrator] Request accepted.
[Orchestrator] Understanding your request and selecting data sources...
[Orchestrator → RAG Agent] Searching uploaded documents...
[Orchestrator → SQL Agent] Querying structured data...
[Orchestrator] Combining evidence and checking worker outcomes...
[Orchestrator] Reviewing answer, numerical claims and citations...
```

上传后的提取、分块、嵌入和存储标注为 `[Data Processing Agent]`。
直接模型回答、图表准备与证据审核属于 Orchestrator，不虚构独立 Agent。
浏览器提交标注为 `[Chat UI → Chat Agent]`；只有服务端返回运行 ID 后，才显示已接受的任务转交。
旧事件或未知阶段保留显示为 `[Workflow]`，不猜测所属 Agent。
这是纯展示变更，保留事件顺序、轮询、自动滚动及错误消息，不增加模型调用，也不修改
A2A 协议或持久化运行格式。

### 上传

`upload()` 最多读取 `MAX_UPLOAD_BYTES + 1` 字节。远程代理先验证工作区权限，
再将原件写入本地存储或私有 Azure Blob，最后携带 `FileRef` 向 Orchestrator 发送 `register_upload`。
A2A 请求不携带文件二进制内容。[Processing Agent](../data_processing_agent/README_CN.md) 随后独立读取原件。
Blob 保存和数据库登记不是分布式事务；登记失败或重复上传可能留下未使用的原件。

### UI 状态

页面标题和浏览器标签页标题均为 **Agent Host Workshop - Module 06**。
标题、Session 控件和上传控件作为整体固定在顶部，不随聊天内容滚动。
在较矮的屏幕上，该区域最多占视口的一半，并可在内部滚动，以便访问所有控件且不遮挡输入区。
工具栏不再显示公开访问和顺序上传的提示；这不改变访问权限、多文件上传或重试行为。

状态轮询遇到可重试错误时，会在运行期限内重新连接同一个运行，最多三次（分别等待 1/2/3 秒），
不会自动重复发送文件 POST。若重连仍失败，请保留页面并点击 **Retry last request**：
跳过已完成的队列项，对已获得的运行 ID 继续轮询。传输错误不代表摄取失败，应核对持久化文件/运行状态。
请等队列完成后再刷新以加载新 UI；选中的文件和队列状态保存在页面内存中。

`sessionStorage` 按工作区保存会话 ID 和最近 30 条显示消息。UI 最多发送最近六条消息，
每条截断为 3,000 字符，作为模型上下文。访问密钥不会写入这份历史。
清空历史只清理浏览器会话历史，不删除服务端数据。刷新后恢复的是浏览器本地历史，
不是从数据库运行记录重建的历史。渲染使用 `textContent`，支持基本标题/代码块，
不支持任意 HTML，也不是完整 Markdown 引擎。

### 聊天内图表

例如提问：“按国家汇总总利润，并用柱状图和数据表展示。”AI 可选择合适的可视化方式，
也可遵循明确的柱状图/折线图/饼图/数据表请求。Orchestrator 通过 `ChartSelection` 选择源单元格，
由服务端填入真实数值得到 `ChartSpec`，并在证据审核时检查语义。
SQL/HYBRID 图表使用实际查询行；明确要求时，RAG 也可使用绑定检索原文引句的数值，不再仅限数值元数据。
无需在问题中列出数字。展开 **Chart sources** 可查看文件名、页码、记录 ID 和原文引句。
服务端验证引用数字，证据审核检查单位、时期、统计范围和可比性。
文档饼图要求明确的完整分组；检索片段计数不能充当数据集总计。
上传图表只描述摄取计数而非业务指标；业务分析需要后续提问。
明确要求画图但数据不适合或缺失时，显示 `CHART_DATA_UNAVAILABLE` 并保留文字答案。
若需要前后对比的分组柱状图，可每行明确提供一项百分比，例如 `Gen AI shopping: 20% -> 24%`。
服务端解析当前请求，并在图表来源中标注为用户提供的数据；即使 SQL 返回空行，也不妨碍绘图。
每个指标的两组系列并排显示。这不会把任意报告正文或历史消息当成已验证的图表数值。

运行的可选 `charts` 数组保存在现有运行 JSON 中，每张图包含 `kind`、`title`、`source`、
`label_column`、`labels` 和 `series`（`name`、`values`）。限制为四张图、四个系列、40 行、
标签 200 字符，数值必须有限且在 ±10^15 以内。饼图需要单个非负、总和为正的 SQL 系列，
并满足组成部分/整体语义。UI 在渲染不可信的持久化数据前再次验证。
无效图表显示 `INVALID_CHART` 而不丢弃答案，其他图表生成失败也明确报错。
不执行模型 HTML/JS，不加载外部图表库或 CDN。

响应式 SVG 包含无障碍标签、悬停详情、来源/子集说明及可滚动的纯文本数据表。
历史随消息文字保存图表规格和图表错误；同一标签页刷新并重新连接同一工作区后重新渲染。
旧的无图表历史保持兼容。

## 4. 接口与信任边界

| HTTP 接口 | 用途 |
|---|---|
| `GET /`、`GET /static/...` | 浏览器 UI 与资源 |
| `GET /health` | 仅检查进程存活 |
| `POST /api/workspaces`、`GET /api/workspaces` | 创建/列出工作区 |
| `GET /api/workspaces/{workspace_id}` | 检查存在性并读取工作区 |
| `POST /api/workspaces/{workspace_id}/files` | Multipart 上传：`file`、`conversation_id`；返回 202 |
| `GET /api/workspaces/{workspace_id}/files`、`GET /api/workspaces/{workspace_id}/sources` | 列出文档 |
| `GET /api/workspaces/{workspace_id}/datasets` | 列出结构化数据集 |
| `GET /api/workspaces/{workspace_id}/files/{file_id}/status` | 读取处理状态 |
| `POST /api/workspaces/{workspace_id}/chat` | 启动问答工作流；返回 202 |
| `GET /api/workspaces/{workspace_id}/runs/{run_id}` | 轮询业务运行 |

`/api` 免密；任何持有 Chat URL 的人均可访问所配置数据库中的所有工作区。
这是共享 workshop，不是逐用户登录。POST 限流为进程内计数，默认每分钟 60 次；
POST 还要求有界的 `Content-Length`。错误结构包含
`code`、`message`、`request_id`、`retryable` 和 `details`。

配置 `A2A_API_KEY` 后，Chat 还会发布 `/.well-known/agent-card.json` 和 `POST /a2a`，
技能为 `studio`，这些接口要求独立的 peer 密钥。Chat 的 peer 分发器允许工作区、列表、
聊天和运行查询操作，但不允许 `register_upload`；二进制上传走浏览器 HTTP 路径。
Agent Card 校验、任务事件和 Studio JSON 信封见
[shared/a2a_transport.py](../shared/a2a_transport.py)。不要把 peer 密钥放进浏览器。

## 5. 配置、启动与镜像

以下命令都在模块的 **agent-src 根目录**执行，不是在本包目录。先完成
[根目录配置说明](../readme_CN.md)，将 [.env.example](../.env.example) 配置为 `.env`，
执行数据库迁移，并在其他终端分别启动其他服务。

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8080"
python -m uvicorn chat_agent.app:create_app --factory --host 127.0.0.1 --port 8080
```

使用共享的 `A2A_API_KEY`（至少 24 字符），
以及 `ORCHESTRATOR_URL`（本地默认 `http://127.0.0.1:8081`）。
配置 `BLOB_BACKEND`，并按后端选择 `LOCAL_BLOB_PATH` 或 `AZURE_STORAGE_ACCOUNT_URL`。
Azure 存储使用私有的 `data` 容器。本地 Chat 和 Processing 必须共享同一个原件目录/卷。
虽然 Chat 不创建数据库/模型客户端，共用的 `Settings` 模式仍要求填写数据库/模型配置值。

```powershell
az acr build --registry myregistry --image studio-chat:workshop --file chat_agent/Dockerfile --platform linux .
```

这会在名为 `myregistry` 的已有 ACR 中运行 ACR Tasks 快速构建并自动发布镜像；
请替换为 workshop 的 ACR 资源名，不是登录服务器域名。需要 Azure CLI 登录和构建权限，
不需要本地 Docker。可使用部署指南中的脚本一次构建五个角色。
构建上下文必须包含共享包。镜像仅启动 Chat，以 UID 10001 运行，监听容器内的 8080 端口。
Compose、AKS Kata Sandbox 或 ACA Sandbox 的运行方式见
[部署指南（中英文）](../docs/sandbox-deployment_CN.md)；应使用 peer 可达的 URL，而不是其他容器的回环地址。
宿主机 Azure CLI 登录不会自动传入容器。`/health` 不验证外部依赖。

## 6. 测试与当前限制

安装开发依赖后，在同一个根目录执行：

```powershell
python -m pytest -q tests\unit\test_charts.py tests\integration\test_api.py tests\integration\test_a2a.py
node --test tests\ui.test.cjs
```

这些测试覆盖浏览器接口契约、鉴权/错误、上传、远程路由和 UI 安全渲染。
图表测试用模型响应替身验证生产 JSON 输出解析器、来源校验、运行持久化/缓存淘汰、
无效规格、XSS 风格标签、历史恢复和普通聊天。
仅用于离线浏览器测试：在 agent-src 根目录运行：

```powershell
python -m uvicorn tests.chart_runtime:create_chart_test_app --factory --host 127.0.0.1 --port 8096
```

使用测试密钥 `test-only-access-key-12345678`，上传含 `country,profit` 列的 CSV，再询问利润。
该显式测试工具替换 AI/仓储依赖并显示全部四种图表；它不是生产配置，也不能证明模型质量。
测试后停止服务器。
集成测试注入测试模型/仓库，不能证明真实 Foundry/Blob 连通性。
UI 重试会重新执行上次操作；上传队列会继续轮询已接受的运行并跳过已完成项，
但队列本身不能跨页面刷新恢复。当前没有生产级多用户身份机制，
也没有自动 Blob 清理。关于本地测试、镜像运行与云端验收的区别，见
[验收报告](../docs/implementation-report_CN.md)。
