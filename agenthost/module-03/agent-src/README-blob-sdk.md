# agent-src — POC Agent (AKS + agent-sandbox)

一个轻量级、有状态的 POC agent，用于部署到 **Module 3 (Solution B)** 创建的 AKS 集群中，
并通过 `agent-sandbox.yaml` 以 `Sandbox` 自定义资源的形式运行。

当前实现与 [app/main.py](app/main.py) 保持一致，核心目标有三项：

1. 提供一个简单的网页聊天入口
2. 通过 APIM 暴露的 `/openai/v1` Responses API 与后端模型对话
3. 通过挂载的 Blob volume 持久化对话状态，并在重启后恢复历史

同时，应用会在 Foundry project 中创建或复用一个**持久 agent**，因此该 agent 可以在 Foundry catalog 中被看到和管理。

## 核心特性

| 特性 | 实现 |
|---|---|
| **网页聊天 UI** | `portal.html` + `/` 根路径 |
| **后端 AI 对话** | `ReflectionAgent` 调 `FoundryResponsesClient.reflect()` |
| **Foundry catalog 可见** | 启动时使用 `azure-ai-projects` 在 `FOUNDRY_PROJECT_ENDPOINT` 中创建或复用 `FOUNDRY_AGENT_NAME` |
| **模型经 APIM** | `AGENT_APIM_ENDPOINT` + `/openai/v1`，使用 Responses API |
| **Microsoft Agent Framework** | `agent_framework.Agent` + `OpenAIChatClient`（Responses API 路径） |
| **Azure OpenAI SDK** | `AsyncOpenAI` 作为底层客户端，通过 APIM 调用 OpenAI-compatible 接口 |
| **Workload Identity** | `DefaultAzureCredential` + `get_bearer_token_provider(...)` |
| **状态持久化** | 在 Blob CSI 挂载目录中按 `<AGENT_ID>.json` 保存 |
| **状态恢复** | 启动时从挂载目录读取 `history` 和 `reflection_count` |
| **K8s 探针** | `/health`（liveness）、`/ready`（readiness） |

## 工作方式

### 1. 启动时

- 读取 `app/.env`（仅在环境变量未设置时作为默认值）
- 初始化挂载目录上的文件状态存储
- 连接 Foundry project，创建或复用一个持久 agent
- 构建指向 APIM `/openai/v1` 的 Responses client
- 从挂载目录恢复此前的聊天历史
- 启动 HTTP 服务和网页聊天界面

### 2. 每次聊天请求

- 浏览器向 `/reflect` 发送 `{"query": "..."}`
- 服务读取当前内存中的历史记录
- 取最近几轮上下文，调用 Responses API
- 将 `{query, response, timestamp}` 追加到 `history`
- 把更新后的状态原子写回挂载目录
- 将结果返回给前端页面

### 3. Pod 重启后

- 应用再次启动时从 `<STATE_MOUNT_PATH>/<AGENT_ID>.json` 读取状态
- 恢复此前的 `history` 和 `reflection_count`
- 前端打开 `/` 时会调用 `/state`，把历史消息重新渲染出来

## 目录结构

```text
agent-src/
├── app/
│   ├── main.py          # 应用入口（FileStateStore + FoundryResponsesClient + HTTP server）
│   ├── portal.html      # 聊天网页 UI
│   ├── .env             # 本地运行配置
│   └── .env.example     # 配置模板
├── Dockerfile           # 构建容器镜像（build context = agent-src/）
├── requirements.txt     # agent-framework-openai + azure-ai-projects
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

# 使用本地可写目录保存状态；不配置 Foundry/APIM 时模型响应会被模拟
$env:STATE_MOUNT_PATH="$PWD/data"
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

如果未配置 APIM 或 Foundry，返回结果可能是模拟响应；这是预期行为。

---

## 场景 2 — 本地连接 Foundry 与 APIM

如果要在本地走真实 Azure 路径，需要满足以下条件：

1. 已执行 `az login`
2. 当前身份对 Foundry project 有权限（至少能列出 / 创建 agent）
3. `STATE_MOUNT_PATH` 指向本地可写目录
4. APIM 网关允许该身份的 Bearer token 通过

建议直接编辑 `app/.env`：

```env
STATE_MOUNT_PATH=./data
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
- 聊天历史会写入 `<STATE_MOUNT_PATH>/<AGENT_ID>.json`
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

最简单的方式是继续使用 Module 3 的一键脚本：

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

## 状态持久化

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

- `STATE_MOUNT_PATH` 指向同一个可写持久卷
- `AGENT_ID` 稳定不变

如果 `AGENT_ID` 发生变化，应用会读写另一份 JSON 文件，看起来就像“历史丢失”。

---

## 认证与授权

应用使用 `DefaultAzureCredential`。

### 对状态卷

应用本身不再调用 Blob SDK，也不需要 Blob 数据面凭据。AKS Blob CSI
配置负责挂载和身份验证；容器内运行用户需要对 `STATE_MOUNT_PATH` 具备读写权限。

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
| `AGENT_ID` | `agent-poc-001` | Agent 唯一标识，也决定状态文件名 |
| `STATE_MOUNT_PATH` | `/app/app/data` | Blob volume 在容器内的挂载路径 |
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
| `[Volume] Save failed ...` | 挂载目录不存在、只读或容器用户没有写权限 |
| `[Volume] No prior state ...` | 这是首次运行或对应的 `<AGENT_ID>.json` 还不存在 |
| `[Foundry] Catalog registration failed ...` | Foundry project endpoint 错误，或身份无 agent 管理权限 |
| `[AI] No APIM base_url` | 未设置 `AGENT_APIM_ENDPOINT`，会降级为模拟响应 |
| `[AI] Request failed: 401 ...` | APIM 鉴权失败；检查 token scope、UAMI 权限、APIM validate-jwt 配置 |
| 重启后历史未恢复 | 检查 `STATE_MOUNT_PATH`、volume mount 和 `AGENT_ID` 是否稳定一致 |
| 返回 `[Simulated] ...` | 说明 AI client 未成功初始化，通常是 APIM / SDK / 身份配置未就绪 |
