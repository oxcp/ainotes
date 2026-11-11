# Data Processing Agent：将上传文件转换为关系数据与向量

[English](README.md) | [模块概览（英文）](../README.md) | [Orchestrator](../orchestrator_agent/README_CN.md)

## 1. 职责与设计

这个 Worker 读取已登记原件、提取内容、推断结构化列、切分有效文本、生成向量并提交数据。
它**不回答问题，不使用生成式 LLM 分类文件，也不运行 LangGraph**。
分类由确定性逻辑完成：同时有行和文本块为 `HYBRID`，只有行为 `STRUCTURED`，否则为 `UNSTRUCTURED`。

服务通过 A2A 接收 `FileRef`，不是文件二进制或任意 URL。原件保存在 Blob；
关系数据、向量和处理报告保存在 PostgreSQL/vector 中，共用 HorizonDB / Azure PostgreSQL Flexible Server 的 psycopg 仓储。
Embedding 使用共享的 OpenAI SDK 适配层，不使用 LangChain 或 Microsoft Agent Framework。

## 2. 代码阅读指南

| 文件 / 符号 | 实现内容 |
|---|---|
| [app.py](app.py)：`create_app()` | 在共享服务工厂中选择 `data-processing` 角色 |
| [agent.py](agent.py)：`extract()` | 按格式解析，并区分文档与表格内容 |
| [agent.py](agent.py)：`normalize_columns()`、`infer()`、`convert()`、`table_data()` | 安全列名、确定性类型推断/转换和行校验 |
| [agent.py](agent.py)：`chunk_sections()` | 有 token 上限、重叠、Unicode 安全边界和来源元数据的分块 |
| [agent.py](agent.py)：`DataProcessingAgent.run()` | 已登记文件校验、提取、Embedding、报告生成、入库和失败标记 |
| [shared/storage.py](../shared/storage.py)：`BlobStore.read()` | 工作区/URI 检查、有界读取、大小/校验和验证和格式校验 |
| [shared/database.py](../shared/database.py)：`Repository.ingest()` | 事务、文档行锁、动态数据表、向量行与完成报告 |
| [shared/models.py](../shared/models.py)：`Foundry.embed()` | 批量 Embeddings API 调用和向量数量/维度校验 |
| [Dockerfile](Dockerfile) | 仅启动 Processing；构建时预填充 tokenizer 缓存 |

## 3. 处理流水线与数据映射

```text
Orchestrator -> A2A "process" -> workspace authorization
  -> registered FileRef check -> read original -> extract
  -> infer table schema / chunk document and long-text fields
  -> Embedding API, only if chunks exist
  -> one database ingestion transaction
  -> ProcessingResult + A2A completion artifact
```

### 提取

| 文件类型 | 当前行为 |
|---|---|
| PDF | 提取页面文本并保留页码；拒绝加密文件；没有 OCR |
| DOCX | 提取段落/标题，将表格表示为文本段 |
| TXT / MD | 按段落切分，保留基本标题上下文 |
| CSV | 按 UTF-8 解码，支持 BOM；首行为列头 |
| XLSX | 要求恰好一个有数据的工作表；读取缓存值，不计算公式 |
| JSON | 非空对象数组转换为表格，嵌套值转为 JSON 字符串；其他 JSON 转为文档文本 |

列名会规范化为唯一的 SQL 列名，同时保留 `original_name`。类型推断支持布尔、整数、
小数/货币、ISO 日期/时间戳和文本。`numeric()` 使用 `Decimal`，
移除受支持的货币符号/千位格式，并识别括号表示的负数。
空行/格式错误的行被跳过；不兼容的混合类型保持为文本，而不是静默强制转换。
限制包括最多 60 列、`MAX_ROWS`（默认 50,000 行）和每单元格最多 100,000 字符。

### 分块与 Embedding

`chunk_sections()` 使用 `cl100k_base`，默认 `CHUNK_TOKENS=400`、`CHUNK_OVERLAP=60`。
它将 token 边界映射回原文，并在切片后重新检查 token 长度，避免破坏 Unicode 字符，
也避免重新分词后的文本块超过上限。页码/章节信息会保留。
`language` 元数据只是根据 CJK 字符判断的启发式规则，不是语言识别模型。

对于表格，长文本列或列名匹配 review/comment/feedback/description/response/answer/issue
的列会成为 Embedding 候选。少于 20 字符及完全重复的文本会跳过，但原始关系行仍保留。
向量元数据包含来源行号、字段名及其他非长文本字段值。
Workshop 的 Financial Sample CSV 有显式的文件名例外规则，禁用其长文本列 Embedding。
因此纯结构化输入不需要调用 Embedding。

`Foundry.embed()` 分批请求（默认 `EMBEDDING_BATCH=32`），校验向量数量和
`EMBEDDING_DIMENSIONS`。`MAX_CHUNKS` 默认为 5,000。
Worker 发送 `extract`、`embedding` 和 `storage` 阶段进度；只有存在需要嵌入的文本时才有 `embedding`。

### 事务与重复处理

`run()` 要求传入的 `FileRef` 与已登记文档元数据完全一致。
已完成的文档直接返回保存的报告。`Repository.ingest()` 会在行锁下再次检查：

- 结构化行写入生成的 `ds_<file UUID hex>` 表，附带 `workspace_id` 和 `source_row_id`；
  列描述和行数写入 `datasets`。
- 文档文本向量写入 `document_chunks`；关联表格行的向量写入 `customer_reviews`。
- 文档完成状态与 `ProcessingResult` 在同一个事务内提交。

这能防止已完成入库的重复写入，也覆盖并发调用，但不会消除事务之前并发发生的模型调用。
Blob 上传和 Embedding 调用不在数据库事务内。
处理块发生异常时标记文件失败并向上传播，不会返回伪成功结果。

## 4. A2A 输入输出与边界

Agent Card 声明技能 `process`，Studio 操作也叫 `process`。
必填 `arguments` 为 `workspace` 和 `file`（`FileRef`）。
共享分发器先检查工作区是否存在，再调用 `run()`。
`FileRef` 包含 `file_id`、`workspace_id`、`filename`、`content_type`、`size_bytes`、
`blob_uri` 和 `checksum`；它不代表允许获取任意 URI。

结果为 [ProcessingResult](../shared/contracts.py)：文件标识、分类、存储策略、可选的表名、
载入行数、嵌入记录数、跳过数、警告和状态。
`skipped_records` 混合统计无效/空行及被跳过的短文本/重复文本，不单指被丢弃的关系行。
[Orchestrator](../orchestrator_agent/README_CN.md) 保存报告与进度，供 Chat 轮询。

经过鉴权的发现入口为 `/.well-known/agent-card.json`；
`POST /a2a` 使用官方 SDK 的 JSON-RPC/SSE，以及
[a2a_transport.py](../shared/a2a_transport.py) 中的 Studio 信封。
没有 REST `/process` 上传接口。独立的 `A2A_API_KEY` 不应发送给浏览器。

## 5. 配置、启动与镜像

先完成[根目录配置说明（英文）](../README.md)、`.env` 配置和数据库迁移，
然后在模块的 **agent-src 根目录**执行。正常上传流程还需要分别启动 Chat 和 Orchestrator。

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8082"
python -m uvicorn data_processing_agent.app:create_app --factory --host 127.0.0.1 --port 8082
```

配置 `DB_*`、Blob 参数，以及 Embedding 端点/部署/维度。
`DB_PROVIDER=horizondb`（默认）或 `postgresql`；默认数据库为 `postgres`，五个 Agent 必须一致。
维度必须与迁移和 RAG 一致。共用工厂初始化的 `Foundry` 包含通用与 Embedding 客户端，
所以即使本 Worker 只调用 Embeddings，共享模型字段仍须有效。
参见 [.env.example](../.env.example) 和 [config.py](../shared/config.py)。
各服务的 `A2A_API_KEY` 应一致，且至少 24 字符。
Orchestrator 的 `DATA_PROCESSING_URL` 必须与本服务发布的 URL 一致。

```powershell
az acr build --registry myregistry --image studio-data-processing:workshop --file data_processing_agent/Dockerfile --platform linux .
```

这会在名为 `myregistry` 的已有 ACR 中运行 ACR Tasks 快速构建并自动发布镜像；
请替换为 workshop 的 ACR 资源名，不是登录服务器域名。需要 Azure CLI 登录和构建权限，
不需要本地 Docker。可使用部署指南中的脚本一次构建五个角色。
使用根目录作为构建上下文，不是只有本包。镜像以 UID 10001 运行本角色，监听容器内 8080 端口。
本地原件必须与 Chat 共享；独立云端 Sandbox 使用相同的私有 Azure Blob `data` 容器，
并配置合适的运行时身份。宿主机 Azure CLI 登录不会自动传入容器。
参见[部署指南（中英文）](../docs/sandbox-deployment_CN.md)。`/health` 只检查进程存活。

## 6. 测试与当前限制

```powershell
python -m pytest -q tests\unit\test_workers.py tests\unit\test_boundaries.py tests\integration\test_a2a.py
```

安装开发依赖后，在根目录执行这些命令，覆盖解析、类型推断、Unicode/token 上限、
上传完整性、混合/幂等入库和远程处理。
专门的 [PostgreSQL 测试](../tests/integration/test_postgres.py) 要求配置可丢弃测试数据库，
并显式设置 `STUDIO_TEST_POSTGRES=1`；其他模型相关测试使用替身。

当前没有网页/README URL 抓取器、OCR、多工作表导入、语义去重或自动 Blob 保留策略。
请通过 Chat 上传支持的文件。当前运行/云端证据见
[验收报告](../docs/implementation-report_CN.md)。
