# SQL Agent：受限的自然语言转 SQL 执行

[English](README.md) | [模块概览（英文）](../README.md) | [Orchestrator](../orchestrator_agent/README_CN.md)

## 1. 职责与设计

SQL 将问题转换为一个受约束的 SQL 提案，校验并限定其范围，在工作区结构化数据集上执行，
返回真实查询行。**模型提出 SQL，数据库执行计算。**
Worker 不让 LLM 猜测合计，也不撰写最终叙述答案。
[Orchestrator](../orchestrator_agent/README_CN.md) 将 SQL 结果与其他证据综合，并复核最终答案。

Worker 通过共享 OpenAI SDK 适配层调用通用模型，不使用 Embedding、LangChain SQL Agent/toolkit、
Microsoft Agent Framework 或自己的 LangGraph。
它是固定的“提案—校验—执行”流水线，不是自主探索/修复 SQL 的循环。

## 2. 代码阅读指南

| 文件 / 符号 | 实现内容 |
|---|---|
| [app.py](app.py)：`create_app()` | 在共享服务工厂中选择 `sql` 角色 |
| [agent.py](agent.py)：`SQLAgent.run()` | 读取模式、请求 `SQLProposal`、校验、执行、记录日志并返回 `SQLResult` |
| [shared/agent_service.py](../shared/agent_service.py) | 校验 A2A 参数，调用 Worker 前验证工作区是否存在 |
| [shared/remote.py](../shared/remote.py)：`RemoteSQL.run()` | Orchestrator 侧远程查询代理 |
| [shared/models.py](../shared/models.py)：`Foundry.structured()` | Responses API 与 Pydantic 输出校验 |
| [shared/security.py](../shared/security.py)：`validate_sql()` | PostgreSQL AST 检查、函数/表白名单、工作区改写和数量限制 |
| [shared/database.py](../shared/database.py)：`catalog()`、`query()` | 可用数据集模式与有界只读查询执行 |
| [shared/contracts.py](../shared/contracts.py)：`SQLProposal`、`SQLResult` | 提案和结果契约 |
| [Dockerfile](Dockerfile) | 仅启动 SQL 的镜像入口 |

## 3. 执行逻辑与安全检查

```text
Orchestrator -> RemoteSQL.run() -> A2A "query"
  -> validate workspace exists
  -> Repository.catalog(workspace)
  -> Foundry.structured(question + catalog, SQLProposal)
  -> validate_sql(): AST gate + workspace rewrite + LIMIT
  -> Repository.query(): read-only transaction + statement timeout
  <- SQLResult with executed SQL and actual rows
```

### 模式与生成

`catalog()` 最多返回工作区的 12 个数据集，包括表名、列描述和行数。
空目录在模型调用前抛出 `NO_DATASET`。模型收到问题与目录，而不是无限制的数据库浏览工具。
它必须返回包含最多 8,000 字符 SQL 的 `SQLProposal`。
`Foundry.structured()` 使用 `AsyncOpenAI.responses.create()`、JSON 输出与 Pydantic 校验。
月度趋势生成要求唯一的年月标签、加权利润率（`SUM(profit)/NULLIF(SUM(sales),0)`）
以及连续月份对比。“增收不增利”与利润率下降是不同的判断。
生成阶段收到支持的函数列表。被拒绝的 SQL 可携带校验错误纠正一次；纠正后的查询仍须通过
同一校验才执行。第二次被拒绝时明确失败，绝不执行被拒绝的语句。
结果标明通过校验的查询实际引用的目录文件名；有上限的目录不代表覆盖全部已上传分片。

### 独立 SQL 检查

提示词不是安全边界。`validate_sql()` 使用 SQLGlot 解析 PostgreSQL 语法，并执行：

- 要求恰好一个顶层 `SELECT`，包括受支持的 CTE 查询。
- 拒绝写入/DDL、`SELECT INTO`、锁、参数/占位符以及超过三个 JOIN 的查询。
- 仅允许具名安全函数，包括常见聚合、舍入、字符串/日期操作和部分排名函数；
  不允许 `pg_sleep` 等任意函数。
- 将 SQLGlot 的 `AND`/`OR` 节点识别为布尔运算符而非可调用函数；其子节点仍需通过所有
  函数/表校验，包括 `CASE` 表达式内部的条件。
- 允许 SQLGlot 的类型化 `LAG` 窗口函数进行前期对比；内部表达式仍需通过函数/表校验。
- 通过查询作用域解析物理表，拒绝未批准表和带 catalog/schema 限定的引用。
  查询必须引用至少一个批准的物理数据表。
- 将每个物理表替换为按工作区过滤的子查询，保留引用别名。
- 添加有界顶层 `LIMIT`；保留更小的非负整数字面量限制，移除 `OFFSET`。

例如，物理表已获批准后，改写形态如下：

```sql
-- Before
SELECT SUM(profit) AS total FROM ds_example;
-- After (illustrative workspace UUID)
SELECT SUM(profit) AS total
FROM (
    SELECT * FROM ds_example
    WHERE workspace_id = '00000000-0000-0000-0000-000000000001'
) AS ds_example
LIMIT 100;
```

`ds_example` 用于展示改写，真实表由 [Processing](../data_processing_agent/README_CN.md)
创建，命名为 `ds_<file UUID hex>`。这个示例不是数据库迁移，也不能直接在空数据库执行。

### 数据库执行与结果

`Repository.query()` 打开事务，设置 `READ ONLY` 和事务级语句超时，
然后执行改写后的 SQL。最多获取 `SQL_ROW_LIMIT` 行，序列化结果行超过 16,000 字符时拒绝返回。
默认 `SQL_ROW_LIMIT=100`（最大 500）、`SQL_TIMEOUT_MS=5000`。

`SQLResult.sql` 是实际执行的 SQL，不是未经检查的原始提案。
结果还包括列名、行、行数、简单执行摘要和警告。
Decimal/日期等值转换为 JSON 安全字符串；计算由 PostgreSQL 完成，不通过模型转成浮点数计算。
A2A 的 JSON 字符串信封保留大整数精度，避免转换为 protobuf double。
达到行上限时添加警告，但这并不能证明实际还有更多行。

## 4. A2A 契约与失败行为

Agent Card 声明技能 `query`。Studio 操作 `query` 要求 `workspace` 和 1-4,000 字符的
`question` 字符串。共享分发器在读取模式前校验工作区是否存在。
服务通过经过鉴权的 `/.well-known/agent-card.json` 和 `POST /a2a` 暴露，
没有 REST `/query` 接口。请使用 [RemoteSQL](../shared/remote.py) 和
[共享 A2A 传输层](../shared/a2a_transport.py)。

无效模型输出、`INVALID_SQL`、`UNSAFE_SQL`、缺少数据集、数据库错误和结果过大都会明确失败。
A2A 返回失败任务/错误产物，未知内部异常会做安全脱敏。
没有自动 SQL 修复或伪造结果。Orchestrator 可以对 Worker 级 `TimeoutError` 重试一次，
但这不是对数据库语句错误的通用重试。
HYBRID 中 RAG 成功、SQL 失败时，Orchestrator 可能返回经过复核的部分答案。

工作区改写和只读事务是 workshop 防护，**不是 PostgreSQL RLS**，也不是完整的多租户安全模型。
同一个仓库类还支持其他角色的写入；把本次查询事务设为只读，不代表数据库登录本身只有只读权限。

## 5. 配置、启动与镜像

先完成[根目录配置说明（英文）](../README.md)、`.env` 配置和迁移，
然后在模块的 **agent-src 根目录**执行。查询数据集前，先通过 Chat/Processing 上传结构化数据。

```powershell
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8084"
python -m uvicorn sql_agent.app:create_app --factory --host 127.0.0.1 --port 8084
```

配置 `DB_*`、通用模型端点/部署，以及可选 SQL 行数/超时限制。
`DB_PROVIDER=horizondb`（默认）或 `postgresql` 选择 HorizonDB / Azure PostgreSQL Flexible Server。
两者共用一个 psycopg 仓储，默认数据库为 `postgres`；五个 Agent 必须一致。
共享配置仍要求填写 Embedding 模型字段，即使 SQL 不调用 Embedding；SQL 也不读取 Blob 原件。
参见 [.env.example](../.env.example) 和 [config.py](../shared/config.py)。
各服务的 `A2A_API_KEY` 应一致，且至少 24 字符。
Orchestrator 的 `SQL_URL` 必须与本服务发布的、peer 可达的 URL 一致。

```powershell
az acr build --registry myregistry --image studio-sql:workshop --file sql_agent/Dockerfile --platform linux .
```

这会在名为 `myregistry` 的已有 ACR 中运行 ACR Tasks 快速构建并自动发布镜像；
请替换为 workshop 的 ACR 资源名，不是登录服务器域名。需要 Azure CLI 登录和构建权限，
不需要本地 Docker。可使用部署指南中的脚本一次构建五个角色。
从根目录构建以包含共享代码。镜像仅以 UID 10001 运行 SQL，监听容器内 8080 端口。
Compose/AKS/ACA 和运行时身份参见[部署指南（中英文）](../docs/sandbox-deployment_CN.md)。
宿主机 Azure CLI 登录不会自动传入容器。`/health` 不执行 SQL，也不调用模型。

## 6. 测试与当前限制

```powershell
python -m pytest -q tests\unit\test_workers.py tests\unit\test_boundaries.py tests\integration\test_a2a.py
```

安装开发依赖后，在同一个根目录运行。
这些测试使用替身，覆盖不安全 SQL 拒绝、有范围限制的 SELECT/CTE、精确聚合、工作区隔离与远程错误。
可选的 [PostgreSQL 测试](../tests/integration/test_postgres.py) 使用可丢弃数据库和
`STUDIO_TEST_POSTGRES=1`，验证真实查询、只读事务与超时恢复。

没有 SQL 编写 UI、任意模式访问、自动查询修复或无限结果导出。
函数/表限制有意缩小了表达范围。当前本地与云端验证情况见
[验收报告](../docs/implementation-report_CN.md)。
