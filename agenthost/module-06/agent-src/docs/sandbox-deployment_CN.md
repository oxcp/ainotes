# 独立 Agent 镜像与沙箱

> 🌐 语言 / Language: [English](sandbox-deployment.md) | **中文**

五个生产服务使用 A2A 1.0 JSON-RPC/SSE 通信（官方 `a2a-sdk==1.3.0`）。
LangGraph 保留在 Orchestrator 内部。Chat 和 Orchestrator 都不会构造本地工作 Agent。
五个服务均发布需要身份验证的 `/.well-known/agent-card.json` 并处理 `POST /a2a`。
无需服务注册表：配置可信的对等服务基 URL；客户端先发现并验证卡片，
再使用卡片声明的协议终结点。不要从不可信文档中复制 URL。

## 脚本职责与部署目标

[deploy 目录](../deploy)支持**在 AKS Sandbox 或 ACA Sandbox 上运行五个独立 Agent**。
一次研讨会部署应选择一个目标。构建镜像、生成清单和预配沙箱
是独立步骤；没有任何脚本会预配完整的外围 Azure 基础结构。

对于新的 Linux **Bash + Bicep + ACA CLI** 路径，请遵循
[CLI 部署操作手册](cli-deployment_CN.md)。它在 Module-01 的现有资源组/区域中预配所选数据库，
并复用 Module-04 的现有 SandboxGroup；SDK 仍是替代方案，而非前置条件。

Bash 根入口先通过增量管理面 Bicep 在 Module-01 已有存储账户中创建/复用私有 `data`；
绝不重新部署账户/Blob 服务、修改网络/版本控制/RBAC 或删除数据。
可通过 `bash deploy.sh --stage storage` 重试。
入口自动推导容器 ARM ID；独立 `deploy-aca.sh` 仍要求显式 ID。
只有 Bash 主路径会通过组级共享 `AzureBlobByo` 卷，将此私有 `data` 容器自动只读挂载到
Chat 和 Data Processing 两个沙箱的 `/kb-data`；Orchestrator、RAG 和 SQL 不挂载，详见[挂载前提和失败处理](../../readme_CN.md#挂载已有私有-blobbash-部署必需)。
CLI 会在激活任何 Agent 前以 UID 10001 验证全部挂载；下面的 Python SDK 辅助工具及 AKS 渲染器
尚未实现此自动挂载。应用的 Blob SDK 存储/业务行为保持不变。

| 工具 | 职责 | 目标 / 副作用 |
|---|---|---|
| [build-images.ps1](../deploy/build-images.ps1) | PowerShell：向现有 ACR 提交五次远程 `az acr build` 运行 | 通过 ACR Tasks 构建并发布镜像；不使用本地 Docker，也不部署沙箱 |
| [deploy.sh](../../deploy.sh) | 直接进行 Bash 部署，自动执行前置检查，可选择阶段 | 直接部署计费资源；受保护文件位于模块根目录 `.local` |
| [deploy-storage.sh](../../deploy-storage.sh)、[storage.bicep](../../bicep/storage.bicep) | 直接创建私有 `data`；`--resolve` 只读 ARM 解析账户/容器 ID | 复用 Module-01 账户；不通过 Blob 数据面预配 |
| [build-images.sh](../../build-images.sh) | ACR Tasks 快速构建的 Bash 等效脚本 | 使用相同镜像和 `agent-src` 构建上下文；前置检查通过后直接发布；请统一设置 `IMAGE_TAG` |
| [deploy-database.sh](../../deploy-database.sh) | 自动验证后预配统一 [database.bicep](../../bicep/database.bicep)、vector 允许列表和显式防火墙规则 | 现有 Module-01 资源组和区域；不新建资源组 |
| [deploy-aca.sh](../../deploy-aca.sh) | Bash + `aca`：五个导入/沙箱、URL/配置、可选数据库结构迁移、有时限的健康/卡片/数据库/A2A 检查 | 现有 Module-04 SandboxGroup；不使用本地资源预配 SDK；验证后直接创建计费资源 |
| [render_sandboxes.py](../deploy/render_sandboxes.py) `--target aks` | 生成 Namespace、ServiceAccount、五个 Sandbox CRD、Service 和 NetworkPolicy | 仅写入 JSON；需另行使用 `kubectl` 应用到已准备好的现有 AKS 集群 |
| [render_sandboxes.py](../deploy/render_sandboxes.py) `--target aca` | 生成包含五个镜像/命令/端口的启动清单 | 仅写入 JSON；不是 ARM 模板，也不会创建沙箱 |
| [aca_sandboxes.py](../deploy/aca_sandboxes.py) | 验证配置；加上 `--apply` 后，导入磁盘镜像、创建五个沙箱、连接 URL/配置并进行探测 | 将 ACA 实际部署到现有 SandboxGroup；`--apply` 会创建计费资源 |

`DB_PROVIDER=horizondb` 为默认值，或设置 `DB_PROVIDER=postgresql` / `--provider postgresql`。
五个 Agent 共用通用 `DB_*` 设置、一个 psycopg 仓储和相同迁移，默认数据库为 `postgres`。
两种 PG17 模板输出相同的不含密码的资源/连接清单，ACA 配置组装只提取 `DB_*`。
AKS 渲染器从每个 Agent 的受保护配置 Secret 读取同样的变量。
数据库预配/区域/容量失败不会自动切换提供程序，也不修改 Module-01 的资源。

PowerShell 和 Bash 是可二选一的镜像构建入口。请选择 Bash/ACA CLI 部署
或 Python SDK 部署；不要为计划中的同一组五个实例同时运行两种方式。
`__init__.py` 使 `deploy` 成为 Python 包；它不是部署命令。
以下 Python 示例假设已激活模块虚拟环境（`python` 必须为 Python 3.11+）。

## 镜像

研讨会参考的是 [Module-03 的构建步骤](../../../module-03/prepare-agent-sandbox.sh)：
`az acr build` 通过 ACR Tasks 在 Module-01 的现有注册表中运行快速构建。
[Module-04](../../../module-04/sandbox-deploy.sh) 复用该已发布镜像；它不定义命名的
持久 Task。Module-06 对其五个镜像采用相同的快速构建模式。
这不是 `az acr task run --name ...`；不会创建、修改或假定存在持久 Task。

在安装并登录 Azure CLI、选择目标订阅后，从 `agent-src` 运行。
现有 ACR 必须允许 ACR Tasks，调用者必须有权构建/发布镜像。
云构建不需要本地 Docker CLI/守护进程，也不需要 `az acr login`。

```powershell
az login
az account set --subscription "<subscription-id>"
.\deploy\build-images.ps1 -Registry myregistry -Tag workshop
```

Linux Bash 等效命令：

```bash
az login
az account set --subscription "<subscription-id>"
bash ../build-images.sh --registry myregistry --tag workshop
```

脚本根据自身位置解析构建上下文，因此也可以从其他工作目录通过绝对路径
调用。支持包含空格的路径。`--registry` / `-Registry` 是 ACR
**资源名称**（例如 `acragenthost<deploymentSN>`），而不是 URL 或 `myregistry.azurecr.io`。
`--tag` 默认为 `IMAGE_TAG` 或 `latest`，与 Module-04 一致；当有意选择 `workshop` 标记时，
上述显式使用该标记的示例仍然有效。Bash 也接受 `ACR_NAME`，或通过
`DEPLOYMENT_SN` / Module-01 资源组标记发现现有注册表。`--help` 显示 Bash 用法。每次调用都会等待完成并自动
发布生成的镜像。`--push` / `-Push` 已移除；云构建始终发布镜像。
提交构建会将本地源代码上传到所选 ACR，并可能产生费用。
仅使用经批准的注册表，审查构建上下文，绝不要包含运行时机密。
脚本在首次构建失败时停止，保留已发布的镜像不变。它们不会登录、
创建注册表、重试失败的构建、运行迁移或部署容器。
通过 `bash` 调用时无需设置可执行位。

例如，Chat 步骤运行 `az acr build --registry myregistry --image studio-chat:workshop
--file chat_agent/Dockerfile --platform linux <agent-src-root>`。每个角色使用自己的 Dockerfile。
Compose 和 Python 部署工具使用的登录服务器是另一个值：

```bash
az acr show --name myregistry --query loginServer --output tsv
```

将返回的主机名用于 `ACR_LOGIN_SERVER` 以及下面的 Python 部署 `--registry` 参数。
不要将不带域名的 ACR 资源名称传给清单渲染器或 ACA 镜像导入器。

| 角色 | Dockerfile / 入口 | 镜像 |
|---|---|---|
| Chat | `chat_agent/Dockerfile`、`chat_agent.app:create_app` | `studio-chat` |
| Orchestrator | `orchestrator_agent/Dockerfile`、`orchestrator_agent.app:create_app` | `studio-orchestrator` |
| Processing | `data_processing_agent/Dockerfile`、`data_processing_agent.app:create_app` | `studio-data-processing` |
| RAG | `rag_agent/Dockerfile`、`rag_agent.app:create_app` | `studio-rag` |
| SQL | `sql_agent/Dockerfile`、`sql_agent.app:create_app` | `studio-sql` |

构建上下文是本模块的 `agent-src` 目录，而不是单个包。共享 Python 库
打包在一起，但每个镜像只启动其指定 Agent。镜像以 UID 10001 运行，监听 8080，
并包含分词器缓存。重复的根 Chat Dockerfile 已移至
[notmust](../../notmust/agent-src/Dockerfile)；请使用 `chat_agent/Dockerfile`，构建上下文仍为 `agent-src`。
[.dockerignore](../.dockerignore) 会从上传上下文中排除 `.env`、`.env.*`（`.env.example` 除外）、`.local`、
虚拟环境和测试/构建产物。不要将机密文件放在源代码树的其他位置。
绝不要将凭据固化到镜像中。`/health` 确认的是进程响应能力，而不是数据/模型连接。

## 本地五服务开发

先在 ACR 中构建/发布，然后设置 `.env`。将 `ACR_LOGIN_SERVER` 设置为
`az acr show` 返回的主机名，将 `IMAGE_TAG` 设置为已构建的标记（默认 `latest`）。五个服务必须
共享同一个对等密钥；无需浏览器/工作区密钥。
此处仅运行/拉取容器时需要 Docker，构建镜像不需要。
Compose 服务没有本地 `build` 定义。

```sh
az acr login --name myregistry
docker compose -f compose.yaml -f compose.agents.yaml pull
docker compose -f compose.yaml -f compose.agents.yaml up -d db
docker compose -f compose.yaml -f compose.agents.yaml run --rm sql python -m shared.database
docker compose -f compose.yaml -f compose.agents.yaml up -d --no-build
docker compose -f compose.yaml -f compose.agents.yaml ps
```

只有 Chat 发布到 `127.0.0.1:8080`；其他服务通过 Compose 网络发现。
本地原始文件使用同时挂载到 Chat 和 Processing 的共享开发卷。这**不是**云
存储设计。DefaultAzureCredential 仍需要各容器内部存在有效身份：主机上的 `az login`
不会自动为容器进行身份验证。通过环境变量/机密提供开发服务主体凭据，
或使用 Azure CLI 身份运行本地 Python 进程。不要挂载整个主目录。
将容器凭据设置与生产 AKS 工作负载身份分开。

若使用五个本机终端，请激活同一虚拟环境，然后设置公共 URL 并启动对应
入口。`.env.example` 中的对等服务 URL 已对应端口 8081-8084：

```powershell
# Example Orchestrator terminal; repeat for chat:8080, data_processing:8082, rag:8083, sql:8084.
$env:A2A_PUBLIC_URL = "http://127.0.0.1:8081"
python -m uvicorn orchestrator_agent.app:create_app --factory --host 127.0.0.1 --port 8081
```

Linux Bash 等效命令，同样从 `agent-src` 运行：

```bash
A2A_PUBLIC_URL=http://127.0.0.1:8081 \
  python -m uvicorn orchestrator_agent.app:create_app --factory --host 127.0.0.1 --port 8081
```

## AKS Sandbox（Module-03 模式）

前置条件：具有 agent-sandbox 控制器和 `agents.x-k8s.io/v1beta1` Sandbox CRD 的 AKS 集群，
采用 `kata-vm-isolation` 的 Azure Linux Kata 节点池、Module-03 标签/污点约定、已启用工作负载身份
和 OIDC、注册表拉取授权，以及到 Blob、HorizonDB 和模型终结点的网络访问。
本模块**不会**修改或安装 Module-03 资源。

```powershell
python deploy\render_sandboxes.py --target aks --registry myregistry.azurecr.io --tag workshop `
  --namespace studio --identity-client-id <uami-client-id> --output .local\aks-sandboxes.json
kubectl create namespace studio
```

Linux Bash 等效命令：

```bash
python -m deploy.render_sandboxes --target aks --registry myregistry.azurecr.io --tag workshop \
  --namespace studio --identity-client-id "<uami-client-id>" --output .local/aks-sandboxes.json
kubectl create namespace studio
```

运行云命令前，请将引号内的占位符替换为现有资源的标识符。
渲染器不会创建集群、安装 Sandbox 控制器或配置工作负载身份。

针对每个角色，从受保护的环境文件创建一个名为 `studio-<role>-config` 的 Kubernetes Secret。
使用角色名称 `chat`、`orchestrator`、`data-processing`、`rag`、`sql`。
每个 Secret 必须包含 `.env.example` 中的键，并填写真实云终结点、TLS 和凭据；渲染器
会覆盖 `BLOB_BACKEND=azure` 以及所有 A2A 终结点变量。对等密钥须保留在服务端。
当前共享设置架构即使对 Chat 也要求数据库/模型值，但 Chat 从不构造数据库/模型客户端。
在多租户使用之前，应补充生产级最小权限配置隔离。

```powershell
# Example; keep the source file outside version control.
kubectl -n studio create secret generic studio-chat-config --from-env-file=.local\chat.env
```

在版本控制之外准备好全部五个受保护的环境文件后，运行 Linux Bash 命令：

```bash
(
  set -e
  for role in chat orchestrator data-processing rag sql; do
    kubectl -n studio create secret generic "studio-${role}-config" \
      --from-env-file=".local/${role}.env"
  done
)
```

使用集群 OIDC 颁发者和受众 `api://AzureADTokenExchange`，将指定 UAMI 与五个服务帐户主体分别建立联合：
`system:serviceaccount:studio:studio-<role>`。
根据需要授予模型和存储数据平面角色；为集群的
镜像拉取身份授予注册表访问权限。单个共享 UAMI 是研讨会基线，而不是生产信任边界。

```powershell
kubectl apply --dry-run=server -f .local\aks-sandboxes.json
kubectl apply -f .local\aks-sandboxes.json
kubectl -n studio get sandboxes,pods,services
kubectl -n studio port-forward service/studio-chat-api 8080:8080
```

Linux Bash 等效命令（仅在服务器端试运行成功后应用）：

```bash
(
  set -e
  kubectl apply --dry-run=server -f .local/aks-sandboxes.json
  kubectl apply -f .local/aks-sandboxes.json
  kubectl -n studio get sandboxes,pods,services
  kubectl -n studio port-forward service/studio-chat-api 8080:8080
)
```

五个 Sandbox 对象运行独立的 Kata Pod。显式的 `-api` ClusterIP Service 避免与
控制器创建的服务冲突。命名空间范围的 NetworkPolicy 仅允许 Chat → Orchestrator → 工作 Agent；
除管理用途的端口转发外，拒绝 Chat 入站流量。如需外部 Chat 入口，请添加 TLS 入口/网关
及其显式 NetworkPolicy 规则。不会创建公共 LoadBalancer。本示例不限制出站流量；
生产环境应配置经批准的 DNS、模型、Blob 和数据库目标。
集群内部使用 HTTP 是为研讨会作出的简化：如果网络不可信，请使用 mTLS/服务网格或 TLS 终结点。
A2A 持有者密钥不会加密流量。已挂起的工作 Agent 会返回明确的不可用/超时结果；
未实现自动唤醒网关。

## ACA 沙箱（Module-04 运行时模型）

这里指的是 **Microsoft.App/SandboxGroups 和独立沙箱微型虚拟机**，而不是普通 Container Apps，
也不是 Dynamic Sessions。请使用受支持的 [ACA Sandboxes 门户](https://sandboxes.azure.com/)。
Module-04 的旧脚本包含占位生命周期命令；本模块不会复制这些命令。

生成启动清单（不是 ARM 部署模板）：

```powershell
python deploy\render_sandboxes.py --target aca --registry myregistry.azurecr.io --tag workshop `
  --output .local\aca-launch.json
```

Linux Bash 等效命令：

```bash
python -m deploy.render_sandboxes --target aca --registry myregistry.azurecr.io --tag workshop \
  --output .local/aca-launch.json
```

### 显式 SDK 部署

仅使用 Shell 的替代方案见 [CLI 部署](cli-deployment_CN.md)，其中包括准确的前置条件、
HorizonDB 预配、受保护的配置组装、启动检查、结果输出和失败处理。

预览版 SDK 的包版本为 `azure-containerapps-sandbox==0.1.0b4`（需要检查预发行版本）。
部署辅助工具使用其经过验证的磁盘镜像、沙箱、端口和文件传输 API。它面向
**现有** SandboxGroup，绝不会创建/删除外围资源组。

将 `.local/aca-config.json` 准备为恰好包含五个键的对象：`chat`、`orchestrator`、`data-processing`、
`rag`、`sql`。每个值都是 `.env.example` 环境变量的字符串到字符串映射，需填写适用于
Azure 的值。所有角色使用相同的 A2A 对等密钥和外部数据源配置，不存在工作区密钥。
使用 `BLOB_BACKEND=azure` 和
数据库 TLS；提供适合经批准的来宾身份验证机制的运行时身份变量。
不要将此机密文件纳入源代码管理。辅助工具会在分配端口后替换 A2A URL 变量。
激活前需另行准备数据库结构、权限和来宾身份：此可选工具不会执行 Bash 主路径的
数据库结构引导、四来宾数据库检查或原生 Blob 挂载。

```powershell
python -m pip install -e ".[sandbox]"
python -m deploy.aca_sandboxes --subscription <subscription-id> --resource-group <existing-rg> `
  --sandbox-group <existing-group> --region <region> --registry myregistry.azurecr.io --tag workshop `
  --registry-identity <image-pull-uami-resource-id> --config .local\aca-config.json
# The command above only validates configuration. Add --apply to create billable resources.
```

使用 `--apply` 时，辅助工具会导入五个磁盘镜像、启动五个沙箱、发布 HTTPS 端口、
上传权限模式为 0600 的配置，并以原子方式激活每个来宾。A2A 端点要求应用级对等认证，
浏览器 API 则保持免密。
它会验证进程健康和经过身份验证的卡片。在每一步之后，将已创建的磁盘/沙箱 ID 和 URL 记录到
`.local/aca-deployment.json`；失败会明确报告，并保留此不含凭据的清理清单。
不会执行自动破坏性回滚。

镜像入口被覆盖为 `python -m shared.sandbox_bootstrap <role>`。它最多等待 600 秒
以获取受保护的配置，然后降权至 UID 10001 并通过 exec 启动 Agent。这避免了依赖交互式 Shell
或后台 `nohup` 进程。经过身份验证的 SDK 将配置作为待生效文件交付，然后
设置所有权并重命名文件；命令不包含任何机密。
匿名平台端口公开 HTTPS 路由。A2A 认证仍是必需的，但浏览器 API 免密：
任何持有 Chat URL 的人都可访问该部署的工作区和数据。
单元测试检查已安装 SDK 的真实签名，不能证明此可选路径已通过云端验收。

### Linux Bash SDK 部署

使用上述相同的受保护 `.local/aca-config.json`、现有 SandboxGroup 和运行时身份
前置条件。从注册表导入镜像之前，Bash 构建脚本必须已推送五个镜像。
激活模块虚拟环境后，从 `agent-src` 运行：

```bash
python -m pip install -e ".[sandbox]"
aca_args=(
  --subscription "<subscription-id>"
  --resource-group "<existing-rg>"
  --sandbox-group "<existing-group>"
  --region "<region>"
  --registry myregistry.azurecr.io
  --tag workshop
  --registry-identity "<image-pull-uami-resource-id>"
  --config .local/aca-config.json
  --output .local/aca-deployment.json
)
python -m deploy.aca_sandboxes "${aca_args[@]}"
```

上述命令仅验证本地配置；不会检查 Azure 权限或部署资源。
审查配置、成本和目标后，在**同一个 Bash 会话**中显式部署：

```bash
python -m deploy.aca_sandboxes "${aca_args[@]}" --apply
```

不要将再次运行 `--apply` 视为幂等更新：辅助工具会生成新的部署 ID 并创建
新的磁盘镜像/沙箱。保留每次部署的清单以便清理；复用默认输出路径
会覆盖先前清单。它既不会创建 SandboxGroup，也不会自动删除资源。

### 门户部署替代方案

1. 选择目标订阅/资源组/区域，创建或复用 **Sandbox Group**。
   操作员需要 **Container Apps SandboxGroup Data Owner** 角色。检查预览版可用性和配额。
2. 在 **Disk images** 中，导入五个注册表镜像。对于私有 ACR，配置受支持的注册表
   身份验证（首选托管身份）。这些是根文件系统：不要假定沙箱启动过程会
   自动运行 Docker CMD。
3. 创建**五个**沙箱，每个使用一个导入的磁盘镜像，并标注其角色。设置 CPU/内存以及
   为这些持续运行的服务禁用自动挂起。Manual 激活端口不会唤醒已挂起的工作 Agent。
   这会产生闲置计算费用；不用时应主动暂停，但不要在活动请求期间挂起。
4. 配置对私有数据/模型的网络可达性。在所有服务中设置 `BLOB_BACKEND=azure`、相同的私有 `data` 容器和
   所选的 HorizonDB/PostgreSQL Flexible Server 数据库。不要跨 ACA 沙箱使用本地文件适配器。
5. 为每个沙箱添加端口 8080，并记录其生成的 HTTPS URL。门户的 **Anonymous** 入口模式
   表示没有平台入口身份验证。应用身份验证保护 A2A 端点及卡片，而不保护浏览器 API：
   任何持有 Chat URL 的人都可访问共享工作区和数据。
   不要移除身份验证后再公开工作 Agent。在可用时采用额外网络限制。
   进程健康路由有意不返回任何机密。
6. 为每个角色准备一个受保护的 `.env`：`A2A_PUBLIC_URL` 等于该沙箱的 HTTPS 基 URL；
   `ORCHESTRATOR_URL`、`DATA_PROCESSING_URL`、`RAG_URL`、`SQL_URL` 等于对应其他沙箱的 URL。
   包含共享对等密钥和数据库 TLS 设置。将 Module-01 UAMI 分配给已有组；
   五个沙箱继承它，`AZURE_CLIENT_ID` 选择它获取 Foundry/Blob/数据库令牌。
   在来宾中验证令牌和数据访问；Bash 主路径会执行这些检查并拒绝服务主体密钥。
7. 使用受支持的 CLI/SDK 文件写入功能，将每个环境文件传输到 `/app/.env`，为 UID 10001 设置
   仅所有者可访问的权限，并根据凭据策略移除本地临时副本。
   不要将机密粘贴到 Shell 命令行、日志、Agent Card 或启动清单中。
   这是门户手工替代路径；Bash 主路径交付受保护的运行 JSON，并通过 `shared.sandbox_bootstrap`
   加载。手工启动 Agent 前，需另行准备/验证数据库结构和身份权限。
8. 从 `/app` 以 UID 10001 启动清单中列出的命令。RAG 来宾 Shell 示例：

   ```sh
   cd /app
   python -m uvicorn rag_agent.app:create_app --factory --host 0.0.0.0 --port 8080
   ```

   使用平台支持的持久进程/会话机制，使进程在交互式 Shell
   退出后仍能运行。断开连接后显式验证响应能力；在终端中启动命令并不能证明
   存在持久启动策略。
9. 验证全部五个 `/health` 终结点、经过身份验证的 Agent Card，然后通过 Chat 测试上传和全部四条
   路由。停止一个工作 Agent，确认返回明确的部分成功/错误结果，然后重启并重试。
10. 记录实际沙箱 ID、镜像摘要、测试结果和清理范围。仅移除
    为本模块创建的资源；绝不要为图方便而删除共享 SandboxGroup 或资源组。

上述门户流程依据官方资料编写；无需任何 Module-04 占位 CLI 命令。
无论使用 SDK 辅助工具还是门户路径，实际镜像转换、来宾启动、身份注入、模型访问和入口
仍属于云端验收步骤。

官方参考：
- [沙箱概述](https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview)
- [磁盘镜像](https://sandboxes.azure.com/docs/sandboxes/disk-images)
- [创建沙箱](https://sandboxes.azure.com/docs/sandboxes/sandboxes)
- [公开端口](https://sandboxes.azure.com/docs/sandboxes/sandbox/ports)
- [传输文件](https://sandboxes.azure.com/docs/sandboxes/sandbox/files)
- [Python SDK 设置](https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-python-sdk)

## 验收边界

Bash 构建包装脚本具有使用 Azure CLI 桩的回归测试，无需 Azure 访问权限或 Docker 即可运行：

```bash
bash -n ../build-images.sh
bash tests/build-images.test.sh
```

PowerShell 等效命令：

```powershell
pwsh -NoProfile -File tests\build-images.test.ps1
```

这些测试验证五次 `az acr build` 调用、相对 Dockerfile 路径、Linux 平台、默认/自定义标记、
输入错误、拒绝已废弃的 push 参数、失败传播，以及从其他工作目录运行时包含空格的路径。
桩不会提交构建，也不能证明注册表/云访问可用。

测试框架使用真实 A2A SDK 和真实回环 HTTP/SSE 启动五个独立操作系统进程。
其模型和共享 SQLite 存储库是明确的**测试夹具**，绝不是生产配置回退项。
这些测试证明的是服务协作，而非 Azure 模型质量、PostgreSQL/vector 兼容性、
容器构建正确性、Kata 隔离或 ACA 微型虚拟机生命周期。请单独报告这些检查。
