# Orchestrator Agent：规划与工作流执行

[English](README.md) | [模块概览（英文）](../README.md) | [Chat](../chat_agent/README_CN.md)

## 1. 职责与设计

Orchestrator 负责工作区授权、上传登记、问题路由、Worker 协作、答案综合/复核和业务运行持久化。
内部使用 **LangGraph `StateGraph`**，通过 **A2A 调用远程 Worker**，
通过 **`Foundry` 封装的 OpenAI SDK 调用模型**。它不使用 LangChain Agent API 或 Microsoft Agent Framework。

图节点是执行步骤，不一定是独立部署的 Agent：规划、汇总和复核在这里执行；
Processing、RAG 和 SQL 在各自的服务中执行。生产装配注入的是
`RemoteDataProcessing`、`RemoteRag` 和 `RemoteSQL`，而不是本地 Worker 实现。

## 2. 代码阅读指南

| 文件 / 符号 | 实现内容 |
|---|---|
| [app.py](app.py)：`create_app()` | 在共享应用工厂中选择 `orchestrator` 角色 |
| [shared/agent_service.py](../shared/agent_service.py)：`create_agent_app()`、`dispatch_studio()` | 构造仓库/模型/Blob 和远程代理，校验并分发 peer 操作 |
| [agent.py](agent.py)：`State` | 图状态：请求 ID、问题/文件、计划、Worker 结果、答案、图表、复核和错误 |
| [agent.py](agent.py)：`build_graph()` | 节点、条件路由、并行分支与有界修订 |
| [agent.py](agent.py)：`start()`、`execute()`、`get_run()` | 后台调度、进度、终态、持久化与查询 |
| [shared/remote.py](../shared/remote.py) | 远程 Worker 代理和 Processing 进度转发 |
| [shared/models.py](../shared/models.py)：`Foundry.structured()` | Responses API 调用、JSON 输出与 Pydantic 校验 |
| [shared/database.py](../shared/database.py) | 工作区存在性检查、文档登记、数据目录与运行持久化 |
| [Dockerfile](Dockerfile) | 只运行 Orchestrator 的进程入口 |

`State.errors` 使用 `Annotated[list[dict], operator.add]`，让并行节点追加错误而不是相互覆盖。
Worker 结果分别写入 `rag_result` 和 `sql_result`。

## 3. 图与执行逻辑

```text
START -> receive_request
  FILE_UPLOAD -> process_uploaded_file -> prepare_charts -> emit_response -> END
  QUESTION -> classify_and_plan
    DIRECT -> direct_llm ----------------------+
    RAG    -> rag_search -> aggregate_results -+-> generate_final_response
    SQL    -> sql_query  -> aggregate_results -+       -> prepare_charts -> review_evidence
    HYBRID -> [rag_search || sql_query]         |            approved -> emit_response
                  -> aggregate_results -------+            revise   -> revise -> generate_final_response
                                                           blocked  -> handle_error -> emit_response
```

- **接收：**通过 `Repository.workspace()` 校验工作区是否存在。
- **上传：**`register_upload()` 检查工作区与预期 Blob URI，按校验和登记文档，
  使用规范化的 `FileRef` 调度 Processing。分布式上传由 Chat 保存原件；
  本地 `upload()` 辅助方法不是生产 Chat 的上传路径。
- **规划：**请求通用模型返回经过校验的 `Plan`，包含 `DIRECT`、`RAG`、`SQL` 或 `HYBRID`，
  以及独立的 `rag_goal` / `sql_goal`。上传绕过模型规划。
- **分发：**DIRECT 不查询工作区证据，直接调用通用模型。RAG/SQL 调用对应的远程 Worker。
  HYBRID 在图中并行执行两个独立分支，再汇总。
- **超时：**每个读取 Worker 使用 `WORKER_TIMEOUT`（默认 120 秒），`TimeoutError` 最多重试一次。
  其他失败记录为明确的 Worker 错误，不伪造结果。上传处理不使用这个 Worker 重试循环。
- **汇总/生成：**两个 Worker 都没有结果时进入 `handle_error`；否则综合检索证据、
  计算事实、解读、建议和局限。DIRECT 首轮复用已有草稿，不再额外调用一次生成模型。
- **图表：**`prepare_charts` 使用共享 `ChartSelection` 的来源/列/行引用，把实际 SQL 单元格、
  RAG 数值元数据或摄取计数解析为有界的 `ChartSpec`。无可用数值或纯文本来源不调用图表模型；
  使用 `WORKER_TIMEOUT` 且超时不重试，图表错误明确显示并保留通过审核的正文。上传图表标题由服务端固定为摄取摘要，
  不推断业务统计。
  无效图表选择携带校验错误纠正一次。SQL 长表分组可通过 `series_column` 将原始单元格透视为最多
  四个系列；重复或不完整的单元格会被拒绝，不会补造零值。空分类标签显示为 `(missing)`。
  仅修订正文时保留有效图表。月度金额趋势和利润率使用独立坐标轴/图表。
  比率类列名（`margin`、`ratio`、`rate`、`pct`、`percent`、`percentage` 或 `%`）不可与其他
  数值共用柱状图/折线图坐标轴。基于 SQL 的评论统计图不从单条评论原文抽取统计数字。
- **复核：**模型检查实际草稿和图表语义。`chart_issues` 中的纯图表问题会移除图表并产生
  `INVALID_CHART`，保留其他方面有效的文字。代码额外要求纠正不在 RAG 结果中的引用 ID，并阻止其他工作区的证据。
  最多修订一次；修订是带着复核意见重新生成答案，不重新执行 Worker 查询。
  再次复核仍未通过时返回错误答案。

空的 `RagResult` 仍然属于结果：检索不足必须披露，但不自动等同于传输失败。
一个 Worker 失败时，另一个 Worker 的成功结果仍可支持部分答案，前提是复核通过。
模型复核不等于对每个数值陈述的确定性正确证明。

## 4. A2A 契约、进度与持久化

Agent Card 声明技能 `studio`。`POST /a2a` 通过共享的
`PeerRequest(operation, arguments)` 契约接收以下 Studio 操作：

| 操作 | 必填参数 |
|---|---|
| `workspaces`、`create_workspace` | 列表无额外参数；创建要求 `name` |
| `workspace`、`files`、`sources`、`datasets` | `workspace` |
| `file_status`、`run` | `workspace` 加 `file_id` 或 `run_id` |
| `chat` | `workspace`、`conversation`、结构化的 `question` |
| `register_upload` | `workspace`、`conversation`、`file` |

它们是 A2A 消息中的操作，**不是独立 REST 路由**。发现和 A2A 请求需要 `A2A_API_KEY`；
工作区不再绑定由密钥派生的 owner。
Peer URL 来自运维配置，Agent Card 会校验角色、技能、端点和协议。

`start()` 立即返回 `request_id`、`run_id` 和 `status=running`。
这代表 A2A 提交任务完成，**不代表业务工作流完成**。Chat 通过独立的 `run` 操作轮询，
直到业务工作流结束。Processing 的 A2A 状态事件写入业务运行的有界进度列表。

`execute()` 使用 `REQUEST_TIMEOUT`（默认 600 秒）和图递归上限 24。
保留最近 100 条进度事件，确定 `completed` / `partial` / `failed` 后调用
`Repository.save_run()`。只有持久化成功才暴露终态；保存失败记为 `RUN_PERSIST_FAILED`。
`get_run()` 先查内存，再查数据库，两条路径都先验证工作区权限。
最多同时运行四个工作流，运行缓存也有上限（`MAX_RUNS`，默认 200）。
可选的 `charts` 数组保存在同一个运行 JSON 中，缓存淘汰后仍可通过 `get_run()` 读取。
无需数据库迁移；[Chat UI](../chat_agent/README_CN.md) 也会在本地历史中保存图表规格。

## 5. 配置、启动与镜像

先完成[根目录配置说明（英文）](../README.md)、`.env` 配置和数据库迁移，
然后在模块的 **agent-src 根目录**执行。三个 Worker 要分别启动。
各服务使用相同的 A2A 对等密钥，至少 24 字符；浏览器 API 无需密钥。

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8081"
python -m uvicorn orchestrator_agent.app:create_app --factory --host 127.0.0.1 --port 8081
```

配置 `DATA_PROCESSING_URL`、`RAG_URL`、`SQL_URL`（本地端口分别为 8082、8083、8084）、
`DB_*` 数据库参数、模型端点/部署参数，以及与 Chat/Processing 一致的 Blob 位置。
`DB_PROVIDER=horizondb`（默认）或 `postgresql` 选择 HorizonDB / Azure PostgreSQL Flexible Server。
两者共用一个 psycopg 仓储，默认数据库为 `postgres`；五个 Agent 必须一致。
`Foundry.structured()` 使用 `AsyncOpenAI.responses.create()`、Entra 鉴权和模式校验；
端点选择及共享必填项见 [config.py](../shared/config.py) 和 [.env.example](../.env.example)。
本 Agent 正常工作流使用通用模型，不使用 Embedding。

```powershell
az acr build --registry myregistry --image studio-orchestrator:workshop --file orchestrator_agent/Dockerfile --platform linux .
```

这会在名为 `myregistry` 的已有 ACR 中运行 ACR Tasks 快速构建并自动发布镜像；
请替换为 workshop 的 ACR 资源名，不是登录服务器域名。需要 Azure CLI 登录和构建权限，
不需要本地 Docker。可使用部署指南中的脚本一次构建五个角色。
根目录构建上下文包含共享代码；镜像仅运行本角色，以 UID 10001 运行，监听容器内 8080 端口。
Compose/AKS/ACA、peer 可达 URL 和运行时凭据配置见
[部署指南（中英文）](../docs/sandbox-deployment_CN.md)。宿主机 Azure CLI 登录不会自动传入容器。
`/health` 只检查进程存活，不能证明数据库、模型或 peer 已就绪。

## 6. 测试与当前限制

```powershell
python -m pytest -q tests\unit\test_orchestrator.py tests\unit\test_a2a_transport.py tests\integration\test_a2a.py tests\integration\test_processes.py
```

安装开发依赖后，在同一个根目录运行。测试覆盖四种路由、远程并行、部分失败、超时重试、
修订上限、引用/工作区检查和五进程协作。这些测试使用显式模型替身，不调用真实 Foundry。

这是单调度器的 workshop 设计：已持久化的完成运行可以跨重启读取，但执行中的任务和 A2A
任务历史不会持久化恢复。没有分布式任务队列、多副本调度器、显式 A2A 取消或 Sandbox 自动唤醒。
关闭时取消本地活动工作流并释放资源。真实运行/云端验证情况见
[验收报告](../docs/implementation-report_CN.md)。
