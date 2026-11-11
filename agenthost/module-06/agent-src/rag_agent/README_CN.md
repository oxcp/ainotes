# RAG Agent：检索带来源的证据

[English](README.md) | [模块概览](../readme_CN.md) | [Orchestrator](../orchestrator_agent/README_CN.md)

## 1. 职责与设计

本 Agent 实现 RAG 的**检索部分**，而不是完整的“检索加生成”循环。
它规划来源/主题子查询，将其转为向量，在 PostgreSQL/vector 中搜索已入库文本，检查相关性/工作区并返回证据。
最终答案由 [Orchestrator](../orchestrator_agent/README_CN.md) 综合和复核。
语义检索使用**通用模型进行有上限的查询规划**，使用 **Embedding 模型搜索**，不生成最终答案。

实现采用 OpenAI SDK 适配层加直接仓库查询，不使用 LangChain Retriever/向量存储封装、
Microsoft Agent Framework 或本地 LangGraph。
知识需要先由 [Processing Agent](../data_processing_agent/README_CN.md) 入库。

## 2. 代码阅读指南

| 文件 / 符号 | 实现内容 |
|---|---|
| [app.py](app.py)：`create_app()` | 在共享服务工厂中选择 `rag` 角色 |
| [agent.py](agent.py)：`RagAgent.run()` | Embedding、搜索、校验/过滤结果并返回 `RagResult` |
| [shared/retrieval.py](../shared/retrieval.py) | 来源分组、有上限的来源/主题规划与证据去重合并 |
| [shared/agent_service.py](../shared/agent_service.py) | A2A 操作校验、工作区授权与 Worker 调用 |
| [shared/remote.py](../shared/remote.py)：`RemoteRag.run()` | Orchestrator 侧的 A2A 客户端代理 |
| [shared/models.py](../shared/models.py)：`Foundry.embed()` | Embeddings API 调用与向量形状校验 |
| [shared/database.py](../shared/database.py)：`Repository.search()` | 文档/评论向量合并、余弦评分、过滤和 top-k |
| [shared/contracts.py](../shared/contracts.py)：`Evidence`、`RagResult` | 带来源的结果契约 |
| [Dockerfile](Dockerfile) | 独立 RAG 镜像入口 |

Worker 方法简短是有意的：HTTP/A2A、数据库和模型集成放在共享模块中。
`asyncio.to_thread()` 将同步仓库调用移出异步服务事件循环。

## 3. 检索逻辑

```text
Orchestrator -> RemoteRag.run() -> A2A "retrieve"
  -> validate workspace exists
  -> completed session sources -> source/topic plan (at most 6 searches)
  -> Foundry.embed(semantic queries with English translations)
  -> source-scoped Repository.search(..., filenames=...) (at most 3 concurrent)
  -> threshold / top-k / workspace and source checks
  -> round-robin merge, deduplicate, bound context and report coverage
  <- RagResult with Evidence[]
Orchestrator -> final generation and evidence review
```

1. 分发器接受 1-4,000 字符的查询字符串，最多八个过滤项。
2. 通用模型根据有上限的已完成文件目录规划最多六个来源/主题子查询。
   同一来源的分片一起检索，原始文件保持独立。两份报告、三个主题可分别进行六次检索。
   查询包含英文译词，不再将整段任务指令或重复的报告标题/页脚作为向量查询。
   Embedding 模型及维度必须与入库匹配；仅维度相同不足以保证语义兼容。
3. `Repository.search()` 使用 `UNION ALL` 同时搜索 `document_chunks` 和 `customer_reviews`。
   两个分支都按工作区限制，并关联对应文档获取来源标识。服务端将规划的来源索引解析为
   实际文件名，以 SQL 参数绑定，并与用户过滤条件取交集。
   请求中的评分范围和情感标签规划为类型化 `review_filter` 条件，在向量排序和 `TOP_K`
   截断前应用，而不是作为语义关键词。高分负评、低分好评分开检索；没有匹配项时明确披露证据缺口。
   仅按评分和情感选取例子时，`metadata_only` 要求同时具备这两类条件，按向量相似度排序但不设相关性
   截断阈值。指定具体主题时仍保留阈值；覆盖警告区分元数据条件样本与超过语义阈值的证据。
4. 相似度为 `1 - cosine_distance`，使用 PostgreSQL/vector 的 `<=>` 运算符。
   仓库应用适用的阈值与精确匹配过滤，按分数降序排列，并限制为 `TOP_K` 条。
5. `RagAgent.run()` 校验每个 `Evidence`，再次检查适用的阈值和数量上限。
   如果返回项的工作区或来源不属于请求范围，抛出 `ISOLATION_FAILURE`。
6. 在各子查询之间轮流取证，按 record ID 去重。合并上限为
   `min(12, max(TOP_K, 2 * search_count))`，序列化证据另受 14,000 字符预算限制。
   无证据时为 `insufficient`；有子查询无结果或合并被截断时为 `weak`。
   覆盖警告逐项给出来源、查询与保留的候选数量。`sufficient` 仍不证明主题完整性：
   Orchestrator 必须核对原文并披露证据缺口。

默认 `RELEVANCE_THRESHOLD=0.4`、`TOP_K=5`，后者是**每次子查询**的上限；
对比查询合并后最多返回 12 条。需同步升级 RAG 和 Orchestrator 的共享结果契约。
这里是精确向量搜索，没有 ANN 索引、重排序或关键词/向量混合检索。
独立的 `review_overview` 策略仍然是有上限的已存评论扫描，不调用模型或 Embedding，
不能据此推断总体数量。

## 4. A2A 契约与来源信息

Agent Card 声明技能 `retrieve`。Studio 操作 `retrieve` 要求：

| 参数 | 含义 |
|---|---|
| `workspace` | 工作区 UUID；校验是否存在 |
| `question` | 查询文本，通常为 Orchestrator 规划的 `rag_goal` |
| `filters` | 可选的字符串键值精确匹配过滤 |

支持的过滤键为 `filename`、`document_id`、`category`、`product`、`language` 和 `date`。
文件名/文档过滤针对来源字段，其他过滤针对已保存元数据。
这里没有日期范围过滤，也不自动推断元数据。未知键会抛出 `INVALID_FILTER`。
过滤是否有用取决于入库时实际生成了哪些元数据。

`RagResult` 包含 `status`、`results`、`top_k`、`retrieval_method`、`truncated` 和 `warnings`。
每个 `Evidence` 包含 `record_id`、`workspace_id`、`document_id`、`filename`、`content`、
`similarity_score`、可选的 `page_number`/`section` 和 `metadata`。
评论证据的仓库元数据包含 `source_row_id`。`record_id` 是 Orchestrator 可以使用的引用 ID；
没有匹配项时，RAG 不会编造文本答案或引用。

经过鉴权的 `/.well-known/agent-card.json` 和 `POST /a2a` 使用独立的 `A2A_API_KEY`。
共享传输层验证对等密钥，并使用官方 SDK 的 JSON-RPC/SSE。
这些操作不是 REST `/retrieve` 路由；请使用 [RemoteRag](../shared/remote.py) 和
[Studio A2A 信封](../shared/a2a_transport.py)。

## 5. 配置、启动与镜像

先完成[根目录配置说明](../readme_CN.md)、`.env` 配置和迁移，
然后在模块的 **agent-src 根目录**执行。通过 Processing 准备文档；空知识库无法返回有依据的证据。

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8083"
python -m uvicorn rag_agent.app:create_app --factory --host 127.0.0.1 --port 8083
```

配置 `DB_*`、Embedding 端点/部署/维度，以及可选的阈值/top-k 参数。
`DB_PROVIDER=horizondb`（默认）或 `postgresql` 选择 HorizonDB / Azure PostgreSQL Flexible Server。
两者共用一个 psycopg 仓储，默认数据库为 `postgres`；五个 Agent 必须一致。
RAG 不读取 Blob 原件。语义查询规划和搜索需要同时配置通用模型及 Embedding 访问。
参见 [.env.example](../.env.example) 和 [config.py](../shared/config.py)。
各服务的 `A2A_API_KEY` 应一致，且至少 24 字符。
Orchestrator 的 `RAG_URL` 必须与发布的、peer 可达的 URL 一致。

```powershell
az acr build --registry myregistry --image studio-rag:workshop --file rag_agent/Dockerfile --platform linux .
```

这会在名为 `myregistry` 的已有 ACR 中运行 ACR Tasks 快速构建并自动发布镜像；
请替换为 workshop 的 ACR 资源名，不是登录服务器域名。需要 Azure CLI 登录和构建权限，
不需要本地 Docker。可使用部署指南中的脚本一次构建五个角色。
根目录构建上下文包含共享代码。镜像仅以 UID 10001 运行 RAG，监听容器内 8080 端口。
Compose/AKS/ACA 和运行时身份见[部署指南（中英文）](../docs/sandbox-deployment_CN.md)；
宿主机 Azure CLI 登录不会自动传入容器。`/health` 只检查进程存活。

## 6. 测试与当前限制

```powershell
python -m pytest -q tests\unit\test_retrieval.py tests\unit\test_workers.py tests\unit\test_boundaries.py tests\integration\test_a2a.py
```

安装开发依赖后，从同一个根目录运行。测试覆盖阈值、过滤、来源、工作区隔离和 A2A 路由。
真实向量查询请使用可选的 [PostgreSQL 测试](../tests/integration/test_postgres.py)，
配置可丢弃测试数据库并设置 `STUDIO_TEST_POSTGRES=1`。
模型替身不能验证真实云端 Embedding 质量。

当前没有网络搜索、URL 抓取、重排序、语义冲突检测或通用答案回退。
没有证据优于编造证据。本地与真实 Azure 服务验证的区别见
[验收报告](../docs/implementation-report_CN.md)。
