# agent-src — POC Agent (AKS + agent-sandbox)

一个轻量级、有状态的 POC agent，用于在 **Module 3 (Solution B)** 创建的 AKS 集群中，
通过 `agent-sandbox.yaml` 以 `Sandbox` 自定义资源的形式部署。

当前实现与 [app/main.py](d:/OneDriveMS/Learning/ainotes/agenthost/module-03/agent-src/app/main.py) 一致，核心目标只有三件事：

1. 提供一个简单的网页聊天入口
2. 通过 APIM 暴露的 `/openai/v1` Responses API 与后端模型对话
3. 把对话状态持久化到 Blob，并在重启后恢复历史

同时，应用会在 Foundry project 中创建或复用一个**持久 agent**，因此该 agent 在 Foundry catalog 中可见、可管理。

## 核心特性

| 特性 | 实现 |
|---|---|
| **网页聊天 UI** | `portal.html` + `/` 根路径 |
| **后端 AI 对话** | `ReflectionAgent` 调 `FoundryResponsesClient.reflect()` |
| **Foundry catalog 可见** | 启动时用 `azure-ai-projects` 在 `FOUNDRY_PROJECT_ENDPOINT` 中创建或复用 `FOUNDRY_AGENT_NAME` |
| **模型经 APIM** | `AGENT_APIM_ENDPOINT` + `/openai/v1`，使用 Responses API |
| **Microsoft Agent Framework** | `agent_framework.Agent` + `OpenAIChatClient`（Responses API 路径） |
| **Azure OpenAI SDK** | `AsyncOpenAI` 作为底层客户端，通过 APIM 调用 OpenAI-compatible 接口 |
| **Workload Identity** | `DefaultAzureCredential` + `get_bearer_token_provider(...)` |
| **状态持久化** | Azure Blob Storage，按 `<AGENT_ID>.json` 保存 |
| **状态恢复** | 启动时从 Blob 读取 `history` 和 `reflection_count` |
| **K8s 探针** | `/health`（liveness）、`/ready`（readiness） |

## 工作方式

### 1. 启动时

- 读取 `app/.env`（仅在环境变量未设置时作为默认值）
- 初始化 Blob 状态存储
- 连接 Foundry project，创建或复用一个持久 agent
- 构建指向 APIM `/openai/v1` 的 Responses client
- 从 Blob 恢复此前的聊天历史
- 启动 HTTP 服务和网页聊天界面

### 2. 每次聊天请求

- 浏览器向 `/reflect` 发送 `{"query": "..."}`
- 服务读取当前内存中的历史记录
- 取最近几轮上下文，调用 Responses API
- 将 `{query, response, timestamp}` 追加到 `history`
- 把更新后的状态写回 Blob
- 将结果返回给前端页面

### 3. Pod 重启后

- 应用再次启动时从 Blob 读取 `<AGENT_ID>.json`
- 恢复此前的 `history` 和 `reflection_count`
- 前端打开 `/` 时会调用 `/state`，把历史消息重新渲染出来

## 目录结构

```text
agent-src/
├── app/
│   ├── main.py          # 应用入口（BlobStateStore + FoundryResponsesClient + HTTP server）
│   ├── portal.html      # 聊天网页 UI
│   ├── .env             # 本地运行配置
│   └── .env.example     # 配置模板
├── Dockerfile           # 构建容器镜像（build context = agent-src/）
├── requirements.txt     # agent-framework-openai + azure-ai-projects + azure-storage-blob
├── lifecycle-hook.sh    # 预留的 preStop 钩子
├── .dockerignore
└── README.md            # 本文档
```

## HTTP API

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/` | 网页聊天 Portal |
| `GET` | `/health` | Liveness 探针 |
| `GET` | `/ready` | Readiness 探针（状态恢复完成后返回 200） |
| `GET` | `/state` | 返回当前状态（含历史记录） |
| `POST` | `/reflect` | 提交查询 `{"query": "..."}`，返回模型响应 |

---

## 场景 1 — 本地快速验证（不连 Azure）

```powershell
cd agent-src
python -m venv .venv
. .venv/Scripts/Activate.ps1
pip install -r requirements.txt

# 不配置 AGENT_STORAGE_ACCOUNT / FOUNDRY_PROJECT_ENDPOINT / AGENT_APIM_ENDPOINT
# 应用会降级为模拟响应，便于本地验证 UI 与 API。
$env:AGENT_RUN_DEMO="true"
python -m app.main
```

另一个终端测试：

```powershell
curl.exe http://localhost:8080/health
curl.exe -X POST http://localhost:8080/reflect `
  -H "Content-Type: application/json" `
  -d '{"query":"What is 2+2?"}'
```

浏览器访问：http://localhost:8080/

如果未配置 APIM / Foundry / Blob，返回可能是模拟结果，这属于预期行为。

---

## 场景 2 — 本地连 Azure（Blob + Foundry + APIM）

本地如果要走真实 Azure 路径，需要满足：

1. 已执行 `az login`
2. 当前身份对 Foundry project 有权限（至少能列出 / 创建 agent）
3. 当前身份对 Blob Storage 有写权限
4. APIM 网关允许该身份的 Bearer token 通过

建议直接编辑 `app/.env`：

```env
AGENT_STORAGE_ACCOUNT=stcagenthost<SN>
AGENT_BLOB_CONTAINER=agent-state
FOUNDRY_PROJECT_ENDPOINT=https://foundry-agenthost-<SN>.services.ai.azure.com/api/projects/maf-agent-prj
FOUNDRY_AGENT_NAME=agenthost-reflection-agent
AGENT_APIM_ENDPOINT=https://apim-agenthost-<SN>.azure-api.net/foundry
LLM_MODEL=gpt-5.4-mini
LLM_TOKEN_SCOPE=https://ai.azure.com/.default
```

然后启动：

```powershell
python -m app.main
```

启动成功后：

- Foundry catalog 中可以看到 `FOUNDRY_AGENT_NAME`
- 聊天历史会写入 Blob：`<AGENT_ID>.json`
- 再次启动时会自动恢复历史

---

## 场景 3 — 构建镜像并推送到 Module 1 的 ACR

```bash
RESOURCE_GROUP="rg-agenthost-workshop"
SN=$(az group show -g "$RESOURCE_GROUP" --query "tags.deploymentSN" -o tsv)
ACR_NAME="acragenthost${SN}"

az acr login --name "$ACR_NAME"
docker build -t "${ACR_NAME}.azurecr.io/agent-host:poc-v1" agent-src/
docker push "${ACR_NAME}.azurecr.io/agent-host:poc-v1"
```

---

## 场景 4 — 部署到 AKS（通过 agent-sandbox.yaml）

最简单的方式仍然是使用 Module 3 的一键脚本：

```bash
cd module-03
IMAGE_TAG=poc-v1 ./deploy.sh
```

脚本会完成：

- 构建并推送 `agent-src/` 镜像
- 安装 agent-sandbox controller
- 创建运行时所需的 Kubernetes Secret（如 `agent-config`）
- 生成并应用 `agent-sandbox.yaml`

部署后验证：

```bash
kubectl get sandbox,pods -n agent
kubectl logs -n agent -l app=agent-host --tail=50

kubectl port-forward -n agent svc/agent-host 8080:80
curl http://localhost:8080/state
curl -X POST http://localhost:8080/reflect \
  -H "Content-Type: application/json" \
  -d '{"query":"What is machine learning?"}'
```

浏览器访问：http://localhost:8080/

---

## 状态持久化说明

当前实现**不再使用 Redis 作为应用状态存储**。

状态结构保存在 Blob 中，文件名为：

```text
<AGENT_ID>.json
```

其中包含：

- `agent_id`
- `created_at`
- `resumed_at`
- `reflection_count`
- `history`

`history` 的每一项形如：

```json
{
  "query": "hello",
  "response": "hi",
  "timestamp": "2026-07-20T00:00:00+00:00"
}
```

因此，恢复历史的关键是：

- `AGENT_STORAGE_ACCOUNT` 正确
- `AGENT_BLOB_CONTAINER` 正确
- `AGENT_ID` 稳定不变

如果 `AGENT_ID` 改了，应用会读写另一份 Blob 文件，看起来就像“历史丢失”。

---

## 认证与授权

应用使用 `DefaultAzureCredential`。

### 对 Blob Storage

用于：

- 创建容器（若不存在）
- 读取状态 Blob
- 写入状态 Blob

需要对存储账号具备适当的 Blob 数据权限。

### 对 Foundry project

用于：

- 列出已有 agent
- 创建新的持久 agent

需要对 Foundry project 具备相应权限。

### 对 APIM `/openai/v1`

模型调用通过 Bearer token 访问 APIM 网关。

代码中使用：

- `get_bearer_token_provider(DefaultAzureCredential(), LLM_TOKEN_SCOPE)`
- 每个请求通过自定义 `httpx.Auth` 注入新的 `Authorization: Bearer <token>`

这样可以避免长时间运行的 Pod 因 token 过期而失效。

默认 scope：

```text
https://ai.azure.com/.default
```

---

## 环境变量参考

| 变量 | 默认值 | 说明 |
|---|---|---|
| `AGENT_ID` | `agent-poc-001` | Agent 唯一标识，也决定 Blob 文件名 |
| `AGENT_STORAGE_ACCOUNT` | 空 | Blob 存储账号名 |
| `AGENT_BLOB_CONTAINER` | `agent-state` | Blob 容器名 |
| `FOUNDRY_PROJECT_ENDPOINT` | 空 | Foundry project endpoint |
| `FOUNDRY_AGENT_NAME` | `agenthost-reflection-agent` | Foundry catalog 中创建 / 复用的 agent 名称 |
| `AGENT_APIM_ENDPOINT` | 空 | APIM 基础地址；代码自动追加 `/openai/v1` |
| `LLM_MODEL` | `gpt-5.4-mini` | 模型部署名 |
| `LLM_TOKEN_SCOPE` | `https://ai.azure.com/.default` | 获取 Bearer token 时使用的 scope |
| `AGENT_INSTRUCTIONS` | 简短默认值 | 系统提示词 |
| `AGENT_PORT` | `8080` | HTTP 服务端口 |
| `AGENT_RUN_DEMO` | `false` | 启动时运行简短演示 |
| `AGENT_LOG_LEVEL` | `INFO` | 日志级别 |

---

## 故障排查

| 症状 | 说明 / 处理 |
|---|---|
| `[Blob] Unavailable ...` | Blob SDK 不可用、身份无权限、或存储账号名错误 |
| `[Blob] No prior state ...` | 这是首次运行或对应的 `<AGENT_ID>.json` 还不存在 |
| `[Foundry] Catalog registration failed ...` | Foundry project endpoint 错误，或身份无 agent 管理权限 |
| `[AI] No APIM base_url` | 未设置 `AGENT_APIM_ENDPOINT`，会降级为模拟响应 |
| `[AI] Request failed: 401 ...` | APIM 鉴权失败；检查 token scope、UAMI 权限、APIM validate-jwt 配置 |
| 重启后历史未恢复 | 检查 `AGENT_STORAGE_ACCOUNT`、`AGENT_BLOB_CONTAINER`、`AGENT_ID` 是否稳定一致 |
| 返回 `[Simulated] ...` | 说明 AI client 未成功初始化，通常是 APIM / SDK / 身份配置未就绪 |
