# agent-src — POC Agent (AKS + agent-sandbox)

一个轻量级、有状态的 POC agent，用于在 **Module 3 (Solution B)** 创建的 AKS 集群中，
通过 `agent-sandbox.yaml` 以 `Sandbox` 自定义资源的形式部署。

## 核心特性

| 特性 | 实现 |
|---|---|
| **简单推理循环** | 查询 → 调用 LLM → 保存状态 → 返回结果（`ReflectionAgent`） |
| **Foundry catalog 可见** | `foundry` 模式用 **Foundry Agent Service** 创建**持久 agent**，出现在 Foundry catalog / playground |
| **模型经 APIM** | 持久 agent 的模型推理经 **Module 1 的 Foundry AI Gateway 连接**（指向 APIM）路由 |
| **Microsoft Agent Framework** | `agent_framework.Agent` + `AzureAIAgentClient`（foundry）或 `OpenAIChatClient`（gateway） |
| **交互 Portal** | 根路径 `/` 提供网页聊天 UI（单页，无外部依赖） |
| **状态持久化** | Azure Managed Redis（SSL 端口 10000），`agent:state:<id>`，TTL 可配 |
| **休眠 / 恢复** | Pod 重启（agent-sandbox pause/resume）后从 Redis 自动恢复状态 |
| **冷态快照** | preStop `lifecycle-hook.sh` 将状态 flush 到 Blob Storage |
| **K8s 探针** | `/health`（liveness）、`/ready`（readiness） |

## 两种模式（AGENT_MODE）

| 模式 | Foundry catalog 可见 | 模型经 APIM | 实现 |
|---|---|---|---|
| **`foundry`**（默认，✅ 同时满足两点） | ✅ 持久 agent 在 catalog | ✅ 经项目的 Foundry AI Gateway 连接（→ APIM） | `AzureAIAgentClient` + `create_agent` |
| `gateway` | ❌ | ✅ app 直连 APIM | `OpenAIChatClient(base_url=APIM/openai/v1)` |

> **要同时满足「catalog 可见」+「模型经 APIM」→ 用 `foundry` 模式。**
> - **catalog 可见**：app 用 `FOUNDRY_PROJECT_ENDPOINT` + `DefaultAzureCredential` 在 Module 1 项目里
>   `create_agent`（按 `FOUNDRY_AGENT_NAME` 复用），agent 出现在 Foundry catalog，可在 playground 试用。
> - **模型经 APIM**：**不是** app 直连 APIM，而是 Module 1 已在项目上注册的
>   **Foundry AI Gateway 连接**（`foundry-apim-gateway`，category `ApiManagement`，target=APIM）。
>   项目内的模型推理（含 agent 运行）由 Foundry 自动路由到 APIM。
> - **前提**：① UAMI 有项目的 **Azure AI User** 角色（Module 1 已授予）；
>   ② 首次需在门户 **Operate → Admin → AI Gateway → Add AI Gateway → Use existing → Add project to gateway**
>   把项目挂到网关（Module 1 README 步骤 5）。

## 目录结构

```
agent-src/
├── app/
│   └── main.py          # 应用入口（ReflectionAgent + Portal + HTTP server）
├── Dockerfile           # 构建容器镜像（build context = agent-src/）
├── requirements.txt     # agent-framework-openai + redis + azure-identity
├── lifecycle-hook.sh    # preStop 钩子：Redis 状态 → Blob
├── .dockerignore
├── .env.example         # 本地运行配置模板
└── README.md            # 本文档
```

## HTTP API

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/` | **交互 Portal**（网页聊天 UI） |
| `GET` | `/health` | Liveness 探针 |
| `GET` | `/ready` | Readiness 探针（agent 初始化完成后返回 200） |
| `GET` | `/state` | 查看当前 agent 状态（调试用） |
| `POST` | `/reflect` | 提交查询 `{"query": "..."}`，返回 LLM 结果 |

---

## 场景 1️⃣ — 本地快速验证（5 分钟）

```bash
cd agent-src
python -m venv .venv && . .venv/Scripts/Activate.ps1   # Windows PowerShell
pip install -r requirements.txt

# 内存状态 + 启动自演示（无需 Redis / LLM 密钥，使用模拟响应）
$env:AGENT_STATE_BACKEND="memory"
$env:AGENT_RUN_DEMO="true"
python -m app.main
```

另一个终端测试 API：

```powershell
curl.exe http://localhost:8080/health
curl.exe -X POST http://localhost:8080/reflect `
  -H "Content-Type: application/json" `
  -d '{\"query\": \"What is 2+2?\"}'
```

或直接在浏览器打开 **Portal**：http://localhost:8080/ — 输入问题即可交互。

---

## 场景 2️⃣ — 本地 Redis：验证状态恢复（10 分钟）

```powershell
docker run -d --name local-redis -p 6379:6379 redis:7-alpine

$env:AGENT_STATE_BACKEND="redis"
$env:AGENT_REDIS_CONNECTION="localhost:6379"
$env:AGENT_RUN_DEMO="false"
python -m app.main
```

在 Portal（http://localhost:8080/）中对话，然后：

1. 第一次调用 → `reflection_count: 1`
2. `Ctrl+C` 停止，再次 `python -m app.main`
3. 日志出现 `[Redis] State loaded ... reflection_count=1` ✅
4. 刷新 Portal — 历史对话已恢复；再次调用 → `reflection_count: 2`

---

## 场景 3️⃣ — 构建镜像并推送到 Module 1 的 ACR

```bash
RESOURCE_GROUP="rg-agenthost-workshop"
SN=$(az group show -g "$RESOURCE_GROUP" --query "tags.deploymentSN" -o tsv)
ACR_NAME="acragenthost${SN}"

az acr login --name "$ACR_NAME"
# 注意：build context 是 agent-src/ 目录
docker build -t "${ACR_NAME}.azurecr.io/agent-host:poc-v1" agent-src/
docker push "${ACR_NAME}.azurecr.io/agent-host:poc-v1"
```

> 从 `module-03/` 目录执行，或将路径改为 `.`（在 `agent-src/` 内执行）。

---

## 场景 4️⃣ — 部署到 AKS（通过 agent-sandbox.yaml）

最简单的方式是使用 Module 3 的一键脚本，它会自动构建 `agent-src/` 镜像、
安装 agent-sandbox 控制器、创建 Redis/Storage/APIM 密钥，并应用 `agent-sandbox.yaml`：

```bash
cd module-03
IMAGE_TAG=poc-v1 ./deploy.sh
```

部署后验证：

```bash
kubectl get sandbox,pods -n agent
kubectl logs -n agent -l app=agent-host --tail=50

# 通过 port-forward 访问 API
kubectl port-forward -n agent svc/agent-host 8080:80
curl http://localhost:8080/state
curl -X POST http://localhost:8080/reflect \
  -H "Content-Type: application/json" \
  -d '{"query": "What is machine learning?"}'
```

> port-forward 后，浏览器打开 http://localhost:8080/ 即可使用 Portal。

### 观察休眠 / 恢复（scale-to-zero）

```bash
# 暂停（状态 flush 到 Blob；释放计算）
kubectl patch sandbox agent-host -n agent --type merge -p '{"spec":{"pauseRequest":true}}'

# 恢复（从 Redis 自动加载状态）
kubectl patch sandbox agent-host -n agent --type merge -p '{"spec":{"pauseRequest":false}}'
kubectl logs -n agent -l app=agent-host --tail=10 | grep "State loaded"
```

---

## 授权（Bearer Token）说明

应用用 **Microsoft Agent Framework**（`Agent` + `OpenAIChatClient`）调用
Foundry 模型，`base_url` 指向 Module 1 的 APIM AI 网关（`{apim}/foundry/openai/v1`）。

- **本地开发**：设置静态 `LLM_API_KEY`（作为 `api_key` 字符串）。
- **AKS 部署**：**不要**设置 `LLM_API_KEY`。留空时应用用
  `azure-identity` 的 `get_bearer_token_provider(DefaultAzureCredential(), scope)`
  作为 `api_key`（可调用 token provider，自动刷新）。

> **Token scope**：默认 `https://ai.azure.com/.default`（与 module-02 已验证
> 的网关调用一致）。Module 1 网关 `validate-jwt` **仅校验签名 + issuer**
> （本 tenant），**不校验 audience**，因此该 Foundry 数据面 scope 即可通过。
> （若需用 `api://agenthost/.default`，需先创建暴露该 App ID URI 的 Entra
> 应用注册并授权给 UAMI——Module 1 Bicep 未创建，否则无法获取 token。）

底层请求头为：

```
Authorization: Bearer <token>
Content-Type: application/json
```

---

## 环境变量参考

| 变量 | 默认值 | 说明 |
|---|---|---|
| `AGENT_ID` | `agent-poc-001` | 唯一 agent 标识（Pod 名注入） |
| `AGENT_STATE_BACKEND` | `memory` | `memory` 或 `redis` |
| `AGENT_REDIS_CONNECTION` | `localhost:6379` | Redis 连接串（AKS 用 `:10000,...,ssl=True`） |
| `AGENT_REDIS_TTL_SECONDS` | `3600` | 状态在 Redis 的 TTL |
| `AGENT_APIM_ENDPOINT` | （空） | APIM 网关 base URL；应用追加 `/openai/v1` 作为 client base_url |
| `LLM_BASE_URL` | （空） | 完整 client base_url；设置则覆盖 `AGENT_APIM_ENDPOINT` |
| `LLM_API_KEY` | （空） | 静态 Bearer token；AKS 留空→Workload Identity |
| `LLM_TOKEN_SCOPE` | `https://ai.azure.com/.default` | Workload Identity token scope（网关不校验 audience） |
| `LLM_MODEL` | `gpt-5.4-mini` | 模型部署名 |
| `AGENT_INSTRUCTIONS` | （简短默认） | agent 系统提示词 |
| `AGENT_PORT` | `8080` | HTTP 端口 |
| `AGENT_RUN_DEMO` | `false` | 启动时运行自演示（仅本地） |
| `AGENT_LOG_LEVEL` | `INFO` | 日志级别 |

---

## 故障排查

| 症状 | 解决 |
|---|---|
| `[Redis] Connection failed` | 检查 `AGENT_REDIS_CONNECTION`；AKS 用端口 10000 + `ssl=True` |
| `[LLM] HTTP 401` | Token 过期或 scope 错误；检查 UAMI 的 Cognitive Services 角色 |
| 重启后 `reflection_count: 0` | 确认 `AGENT_STATE_BACKEND=redis` 且 Redis 可达 |
| `[LLM] Simulated ...` | 未提供 token 且 Workload Identity 不可用（本地正常，模拟响应） |
