# 通过 Bash 部署可选数据库和五个 ACA 沙箱

> 🌐 语言 / Language: [English](cli-deployment.md) | **中文**

完整的研讨会流程现在从[模块 6：多智能体业务场景操作指南](../../readme_CN.md)开始，
所有命令均在模块根目录运行。本详细参考也以模块根目录为工作目录。

这是 Module-06 的**仅使用 Shell 的资源预配路径**。它复用 Module-01 现有的资源组、
位置、ACR 和镜像拉取身份，以及 Module-04 的**现有 SandboxGroup**。它不会
重新创建这两个共享组，不会使用本地 Docker 构建，也不会调用 Python 资源预配 SDK。
[SDK 辅助工具](../deploy/aca_sandboxes.py)仍可作为替代方案。

完整部署时，根入口会自动从 Module-01 资源发现公共设置，无需手工准备
`.local/aca-common.json`。确认前置条件后运行：

```bash
bash deploy.sh --migrate
```

统一入口直接部署计费资源，请先确认目标和费用。
必要检查自动执行，随后依次部署
storage → models → database → config → images → aca，并生成/复用受保护的管理员密码及
A2A 对等密钥，不生成工作区密钥。`--stage storage`、
`--stage images`
或 `--stage aca` 可显式重试，但不是自动恢复。保留资源清单/配置，部署清单与 `aca-config.json` 不允许覆盖。
显式相对路径以调用者目录为基准。下文是高级单阶段替代操作，不是完整部署后还需执行的步骤。

### 必需的私有 Blob 文件系统视图

根入口从通用 Blob URL、可选的 `STORAGE_ACCOUNT_NAME` / `STORAGE_SUBSCRIPTION_ID` /
`STORAGE_RESOURCE_GROUP` 或 `stcagenthost<SN>` / 资源组标签解析 Module-01 已有账户。
它自动推导并导出 `KB_STORAGE_CONTAINER_ID`，不要求 `data` 已存在。
入口先读取 ARM 验证账户，再通过 `bicep/storage.bicep` 增量预配私有 `data`，其中账户/Blob 服务声明为 `existing`，
绝不重新部署它们、修改网络/版本控制/RBAC 或删除数据。即使禁用公共网络，也通过管理面预配。
账户不存在或运行时 URL/容器 ID 冲突时，阻止所有后续阶段。详见
[操作指南前提](../../readme_CN.md#挂载已有私有-blobbash-部署必需)。
账户必须与通用 `AZURE_STORAGE_ACCOUNT_URL` 一致。`KB_VOLUME_NAME` 默认为 `studio-kb-data`；
`KB_VOLUME_IDENTITY` 默认为镜像拉取身份（`system` 或已有组 UAMI）。
选定身份必须已分配给组，并拥有容器数据读取权限（Storage Blob Data Reader 或更高数据权限）。
验证组/账户还需要 ARM 读取权限，操作员另需容器部署权限。
提前准备存储网络可达性并等待 RBAC 生效，脚本不会预配这些资源。
此认证与来宾 Blob SDK 凭据独立，后者仍然必需。

分阶段部署时，在独立 `deploy-aca.sh` 前创建容器并导出 ID
（独立脚本仍要求显式 ID，且不创建容器）：

```bash
bash deploy.sh --stage storage
export KB_STORAGE_CONTAINER_ID="$(bash deploy-storage.sh --resolve)"
```

已安装的 **aca 1.0.0-preview.5** 帮助验证了以下原生命令：

```bash
# Group-scoped volume: SystemAssigned, or UserAssigned plus --identity-resource-id <group-uami-id>.
aca sandboxgroup volume create --name studio-kb-data --type AzureBlobByo \
  --storage-container-id "$KB_STORAGE_CONTAINER_ID" --identity-kind SystemAssigned
# Repeat for Chat and Data Processing only, with explicit deployment context:
aca sandbox mount --id "$SANDBOX_ID" --volume studio-kb-data --path /kb-data --readonly
```

这些是机制示例，不是部署后额外执行的命令。普通 `AzureBlob` 分配平台自有存储，不能代表已有容器。
卷元数据使用 `storageContainerResourceId`、`auth.kind="ManagedIdentity"` 和
`auth.identity.{kind,resourceId}`，已核对发布的
[`azure-containerapps-sandbox` 0.1.0b4 卷模型](https://pypi.org/project/azure-containerapps-sandbox/)。
脚本先列举，只在不存在时创建，再获取并严格比较元数据，之后才导入镜像。
认证失败不等于不存在，同名但配置不同的卷绝不会静默复用。

ACA 部署会先自动验证本地 CLI 能力和必需输入格式。
随后检查真实账户和身份，仅挂载 Chat 和 Data Processing 两个来宾，验证 `os.path.ismount`，
将探测权限降为 UID/GID 10001，列举容器并读取找到的首个文件。允许空容器。
所有挂载和数据库检查通过后才写入配置激活标记。清单还会在进程重新启动前重复挂载探测。
挂载是运行时连接，不属于镜像内容；组级卷/数据独立于沙箱持久保存。
适用 Blob 缓存/POSIX 语义，这个只读视图不会替换已有 Blob SDK。
可选 Python 预配工具和 AKS 渲染器尚未实现此 Bash 专属自动化。

## 部署内容

| 入口 | 职责 |
|---|---|
| [deploy.sh](../../deploy.sh) | 直接部署，自动执行必要的前置检查：storage → models → database → config → images → aca；`--stage` 可单阶段重试 |
| [deploy-storage.sh](../../deploy-storage.sh) + [storage.bicep](../../bicep/storage.bicep) | 在复用存储账户中通过增量 ARM 仅预配私有 `data`；账户/Blob 服务保持 existing |
| [deploy-models.sh](../../deploy-models.sh) + [embedding.bicep](../../bicep/embedding.bicep) | 同一模板部署账户模型及已有 APIM 的 embeddings 操作/后端；Azure 验证模型/配额/策略；已有授权保持不变 |
| [deploy-database.sh](../../deploy-database.sh) + [database.bicep](../../bicep/database.bicep)、[horizondb.bicep](../../bicep/horizondb.bicep) / [postgresql.bicep](../../bicep/postgresql.bicep) | 选择 HorizonDB 或 PostgreSQL 17 Flexible Server，配置 vector 允许列表和显式防火墙规则；内部函数处理 HorizonDB PATCH/管理员验证 |
| [build-images.sh](../../build-images.sh) | 所有输入/Dockerfile 前置检查通过后直接执行五次远程 ACR Tasks 构建；部署沙箱之前必须已有镜像 |
| [deploy-aca.sh](../../deploy-aca.sh) | 五个私有磁盘导入、五个独立沙箱、HTTPS URL、受保护的配置、可选的数据库结构迁移、有时限的健康检查和结果表 |

所有 Bash 部署/构建脚本都直接运行，可能创建计费资源。必要检查仍然保留：
所选数据库针对所选订阅执行 ARM 验证；ACA 在预配前验证**本地**配置
和清单。仅凭前置检查不能证明云连接可用。
只有 `--migrate` 会启用结构迁移。存储 `--resolve` 和 ACA `--capabilities` 是只读操作。
根入口的镜像前置检查不会提交构建；镜像阶段对五个镜像各构建一次。
模型脚本通过 `bash deploy-models.sh` 直接部署并输出运行时 JSON。
统一入口的 `models` 阶段会将其保存到 `.local/embedding-config.json`；单独重跑 config 需要
此文件，不会再次查询或部署模型。统一入口的 `models` 阶段只调用一次模型脚本。
元数据必须标识当前 APIM/调用者及 `ai.azure.com` scope。旧直连端点元数据会被拒绝；
请先重跑 `--stage models` 再生成配置。模型/APIM 阶段失败会使旧元数据失效。

以下所有命令均在 **Linux Bash** 中从模块根目录运行。支持包含空格的路径。
设置 `SUBSCRIPTION_ID` 或选择目标 Azure CLI 订阅；脚本不会运行 `az login`
或更改当前活动帐户。显式参数优先于非空环境变量，环境变量优先于
默认值。脚本不会自动加载 `.env`。完整的环境变量/默认值表位于
[README](../readme_CN.md#shell-部署默认值)。

```bash
az account show -o none 2>/dev/null || az login
az account set --subscription "<subscription-id>"
export RESOURCE_GROUP="rg-agenthost-workshop"  # the RG already deployed in Module-01
umask 077
mkdir -p .local
chmod 700 .local
```

### 前置条件与边界

- 安装 Azure CLI（含 Bicep）、`aca`、`jq`、`curl`、`openssl` 和 GNU `timeout`。
  ACA 命令/清单已经过 **`aca 1.0.0-preview.5`** 检查。这是独立的
  `aca` CLI，而不是 `az containerapp sandbox` 命令。请使用
  [官方安装说明](https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-cli)；
  执行安装程序前先进行审查。这些脚本不会自动安装任何 CLI。
- 已登录的操作员需要 HorizonDB 部署权限，以及现有 SandboxGroup 上的
  **Container Apps SandboxGroup Data Owner** 角色。
  镜像拉取 UAMI 必须已经具有适当的 ACR 拉取权限。
- HorizonDB 是预览服务。订阅必须已注册提供程序，并在所选区域具备访问权限、容量和
  支持。`LOCATION`（或 `--location`）优先；否则脚本会像 Module-04 一样复用
  **Module-01 的实际资源组位置**。区域不可用或缺少注册会导致
  ARM 验证失败；不会静默回退到其他区域。
- HorizonDB 模板固定使用 `Microsoft.HorizonDb` API **`2026-05-01-preview`**，已根据
  资源架构验证。这些资源没有可用的 AVM。Bicep 0.48.1 编译时没有诊断信息；
  较旧的 0.44.1 可以编译，但会警告其资源类型目录中缺少这些预览类型。
- `DEPLOYMENT_SN`（未设置时使用资源组的 `deploymentSN` 标记）提供默认名称，与 Module 01/04 一致：
  `acragenthost<SN>`、`id-agenthost-<SN>`、`sandbox-group-agenthost-<SN>`、`hdb-agenthost-<SN>`。
  对于自定义资源名称，请覆盖相关脚本参数。ACA 脚本会显式将每次
  云端 `aca` 调用限定到所选的订阅/资源组/组/区域；不会更改全局 ACA 配置。
- **研讨会公共访问：** HorizonDB 使用公共终结点，在 Bicep 模板和 Bash 包装脚本中，
  防火墙范围都默认为 **`0.0.0.0` - `255.255.255.255`**。固定版本的预览 API 使用
  池防火墙规则实现此公共访问；脚本不会添加不受支持的网络属性。
  任何 IPv4 来源都可以尝试连接。TLS 和强数据库身份验证仍然是必需的。
  这是有意采用的、仅限研讨会的设置，不是生产建议。
  如需限制访问，请通过 `DB_FIREWALL_RULES_FILE` / `--firewall-rules-file` 提供经过批准的
  出站地址范围，并安排匹配的网络路径。可通过
  `CUSTOMER_VNET_CONNECTION_NAME` / `--vnet-connection` 选择现有客户 VNet 连接。不会创建 VNet、NAT 或专用终结点。
- 沙箱清单为本研讨会显式允许出站流量。生产环境应采用适当的出站
  策略。发布的端口是公共 HTTPS（`--anonymous`）；A2A 仍需对等密钥，
  但任何持有 Chat URL 的人无需浏览器密钥即可访问其工作区和数据。
  这不是私有服务发现网络。
- 仅有 ACR 导入授权不等于来宾认证。ACA 主路径确保 Module-01 UAMI 被分配到已有
  SandboxGroup，五个来宾继承该身份。`AZURE_CLIENT_ID` 让 `DefaultAzureCredential` 选择它；
  每个来宾都会验证获取令牌，并拒绝服务主体密钥。
  `models` 阶段在已有 Foundry 账户部署 embedding，并在 Module-01 的
  `apim-agenthost-<SN>`（可用 `APIM_NAME` 覆盖）/ `workshop-ai-gateway` 下增加
  `POST /foundry/openai/v1/embeddings`。操作员需要 APIM 子资源部署权限。
  父资源、Responses 和已有推理角色保持不变，不进行 IAM 写入。
  操作在**继承认证之前**验证 Agent UAMI `oid` 及 `https://ai.azure.com` 受众，
  再覆盖后端/重写，使用 APIM 已有**系统分配身份**认证。
  未指定 `client-id` 时不会选择已附加 UAMI。账户 OpenAI 端点隐藏在 APIM 后；
  [官方 v1 embeddings SDK 示例](https://learn.microsoft.com/azure/foundry/openai/how-to/embeddings)
  记录了此端点使用 `https://ai.azure.com/.default`。云端 embedding 调用绝不回退直连访问。
  可用 `--stage models` 重试，不会回退到其他模型、账户或区域。

## 1. 在现有资源组和区域中选择并预配数据库

根入口将 Module-01 UAMI 传给任一提供程序，并启用 Entra 认证。
研讨会将 UAMI 注册为数据库 Entra 管理员，而不是只授予 Azure RBAC。
运行时使用 `DB_AUTH_MODE=entra`，不包含 `DB_PASSWORD`；受保护的管理员密码仍作为预配输入。
来宾引导程序通过 `--migrate` 应用迁移，并在激活前通过回滚的 INSERT/UPDATE/SELECT/DELETE
事务验证真实 SQL 读写权限。生产环境应分离迁移身份和最小权限应用身份。

默认 `DB_PROVIDER=horizondb`，设置 `DB_PROVIDER=postgresql` 或显式 `--provider postgresql`
即可选择 Azure PostgreSQL Flexible Server。仅接受这两个值；错误不会切换后端或区域。
两者共享一个 psycopg 仓储和迁移，Agent、A2A、模型行为不变。所有数据库配置使用 `DB_*`；
部署脚本不会加载 `.env`。所选资源提供程序须已注册并在目标区域有权限和容量；
HorizonDB 额外需要预览访问权限。归档入口 [deploy-horizondb.sh](../../notmust/deploy/deploy-horizondb.sh)
始终选择 HorizonDB。新命令请使用维护中的模块根入口 `deploy-database.sh --provider horizondb`。

在环境中安全设置 `DB_PASSWORD`，或将管理员密码存储在受保护的文件中。
没有默认密码。显式 `--password-file` 会覆盖环境中的密码；否则
`DB_PASSWORD_FILE` 默认为模块根目录 `.local/database-password`，位于镜像上下文之外。
环境变量值会复制到私有临时文件中，并在运行 Azure 命令之前从部署子进程的
环境中移除。只有显式密码模式部署才在运行时配置中使用相同密码；
Entra 主路径仅将其用于资源预配。
例如，仅生成一次新的研讨会密码（不要在这两个步骤之间重新生成）：

```bash
openssl rand -base64 36 > .local/database-password
chmod 600 .local/database-password
```

所要求的研讨会公共访问无需防火墙文件。默认规则为：

```json
[
  {
    "name": "workshop-public",
    "startIpAddress": "0.0.0.0",
    "endIpAddress": "255.255.255.255"
  }
]
```

脚本会针对这条覆盖所有 IPv4 地址的规则打印警告。显式提供的 JSON 文件可以用
更窄的规则或 `[]` 替换它。增量 ARM 部署**不会移除**现有池规则：改用
更窄的规则文件不会撤销先前部署的 `workshop-public` 规则。加固现有集群时，
请显式移除这条宽泛规则；仅添加更窄的规则或传入 `[]` 不会关闭其访问权限。

```bash
export DB_PROVIDER="${DB_PROVIDER:-horizondb}"  # Set postgresql for Azure PostgreSQL Flexible Server
database_args=(
  --password-file .local/database-password
  --output .local/database-deployment.json
)
# Review permissions, networking and cost; ARM validation runs automatically before provisioning:
bash deploy-database.sh "${database_args[@]}"
```

模板创建一个两 vCore 集群，包含一个副本并采用 `BestEffort` 可用区放置策略，同时创建
允许 `vector` 的参数组。未指定 `AGENT_IDENTITY_RESOURCE_ID` 的独立部署使用密码认证；
根入口的 UAMI 路径如前文所述使用 Entra。密码是 Bicep `@secure()` 参数，通过权限模式为 0600 的临时参数文件传入，
绝不会作为明文命令参数或输出出现。临时文件会在正常退出、错误或收到信号时清理。
不要为任何一个脚本启用命令跟踪或 Azure/ACA HTTP 调试日志。

PostgreSQL 模板使用 API `2024-08-01`，创建 PG17 GeneralPurpose Flexible Server，
默认 `DB_SKU_NAME=Standard_D2ds_v5`、`DB_STORAGE_SIZE_GB=32`（自动增长），
设置 `azure.extensions=vector` 和 `require_secure_transport=on`。预配的管理员仍启用密码认证；
提供 UAMI 时还会配置 Entra 认证及管理员，Agent 主路径使用 Entra 而不是管理员密码。
`--sku-name` / `--storage-size-gb` 可覆盖默认值；`DB_VCORES` 仅用于 HorizonDB。
两种模板都使用已有 `postgres` 数据库和同样的显式公网规则。
清单统一为 `status`、`resource_id`、`region` 和字符串 `DB_PROVIDER`/连接设置，不含密码；
失败时保留资源标识和失败阶段，不会自动回滚。Azure CLI 错误内容被抑制以免泄露凭据。

非敏感输出包含 `DB_ENDPOINT`、`DB_PORT`、`DB_DATABASE`、
`DB_USERNAME` 和 `DB_SSL_MODE`。初始研讨会使用集群现有的
**`postgres` 数据库**，而不是尚未创建的 `studio` 数据库。下一步中的 `--migrate` 会在其中安装
现有应用的数据库结构并执行 `CREATE EXTENSION IF NOT EXISTS vector`。对于单独管理的
数据库，请预先创建并授予权限，然后在运行时配置中设置其实际名称。
不要对生产或共享应用数据库执行结构初始化。

集群预配并不是数据库连接测试。ACA 脚本会在启动应用前，
从四个使用数据库的来宾分别检查数据库/结构访问。
管理员帐户是为研讨会提供的便利；生产环境应将迁移凭据与应用
凭据分离，并采用数据库最小权限原则。

## 2. 远程构建五个镜像

```bash
bash build-images.sh
```

这会运行五次 `az acr build` 快速构建并发布镜像，无需本地 Docker 守护进程。
这是单独的计费构建步骤；ACA 脚本仅导入已经发布的镜像。
`ACR_NAME` 和 `IMAGE_TAG` 从环境变量读取，回退值为 `acragenthost<SN>` 和 `latest`。
ACA 导入器和 Compose 使用相同的默认标记。若要复用此前构建的 `workshop` 镜像，
请为构建和部署命令都导出 `IMAGE_TAG=workshop`（或显式传入 `--tag workshop`）。

## 3. 准备运行时凭据与配置

进行新的完整部署时，`deploy.sh` 内的 `resolve_common` 函数发现模型、APIM 和存储设置，
由根入口写入 `.local/aca-common.json`。完整部署会刷新此默认文件，单独重试 config 时复用；
不要直接编辑生成的默认文件来覆盖设置。
需要自定义时，另行准备 `.local/aca-common-custom.json`，并将 `ACA_COMMON` 导出为其路径。
显式指定的输入必须已存在，且不会被覆盖。下例是其中的模型/Blob 部分；
也可使用字符串值提供 `MAX_ROWS`、`REQUEST_TIMEOUT` 等可选运行设置。
config 阶段将数据库/模型部署输出及 UAMI 标识合并到公共配置之上，再添加生成/复用的 A2A 密钥。
不要提供服务主体密钥或工作区密钥。

```json
{
  "BLOB_BACKEND": "azure",
  "AZURE_STORAGE_ACCOUNT_URL": "https://<existing-storage-account>.blob.core.windows.net",
  "AZURE_STORAGE_CONTAINER": "data",
  "AGENT_APIM_ENDPOINT": "https://<existing-apim-host>/foundry",
  "LLM_MODEL": "<deployed-general-model-name>",
  "EMBEDDING_MODEL": "text-embedding-3-small",
  "EMBEDDING_DIMENSIONS": "1536"
}
```

生成的 `FOUNDRY_EMBEDDING_BASE_URL` 为 `<AGENT_APIM_ENDPOINT>/openai/v1`，
`EMBEDDING_TOKEN_SCOPE=https://ai.azure.com/.default`。API base 必须保留 `/foundry`。

config 阶段会自动生成/复用 A2A 对等密钥并组装五角色配置。
**每个环境变量值都必须是字符串。** ACA 阶段使用实际入口 URL 覆盖 A2A URL，
无需手动预测沙箱 URL。单独运行 config 时，需要数据库步骤生成的资源清单和管理员密码文件
（Entra 模式也需要），以及 models 阶段保存且与当前配置匹配的 `.local/embedding-config.json`。

下面是使用自定义输入的独立分阶段路径：先按上述示例创建独立 JSON。
该顺序先刷新模型/APIM 部署元数据，再生成配置；只有保存的元数据已适用于所选 APIM/UAMI 时，
才可省略 models 命令。完整部署成功后无需额外执行这些步骤：

```bash
export ACA_COMMON="$PWD/.local/aca-common-custom.json"
chmod 600 "$ACA_COMMON"
bash deploy.sh --stage models
bash deploy.sh --stage config
```

将所有这些文件保存在已忽略的 `.local` 中；绝不要放入镜像构建上下文或 Git。
包装脚本将输入复制到其私有临时目录，在上传**之前**创建受保护的来宾目录，
上传待生效的 JSON 文件，设置权限模式 `0600`/UID `10001`，然后以原子方式重命名。
配置值绝不会出现在 `aca sandbox exec` 参数中。HTTP 身份验证使用 curl 请求头
**文件**，而不是命令行中的明文持有者密钥。仅按机密管理策略的要求保留原始凭据文件；
脚本会移除自己的临时副本，而不会删除你的输入文件。

上传的是每个角色各自的配置，而不是把完整五角色 JSON 原样交给每个 Agent。
最终文件为 `/app/.local/studio-runtime.json`；其中 `A2A_PUBLIC_URL` 是当前 Agent 自己的 URL。
`shared.sandbox_bootstrap` 将此文件加载到进程环境，再启动 Uvicorn，供 `Settings` 读取。
它不是 Agent Card，不会向浏览器公开，也不依赖 `.env.example` 自动加载。

## 4. 部署并等待全部五个 Agent 就绪

```bash
aca_args=(
  --config "${ACA_CONFIG:-.local/aca-config.json}"
  --output "${ACA_OUTPUT:-.local/aca-deployment.json}"
)
# First deployment into a new workshop database:
bash deploy-aca.sh "${aca_args[@]}" --migrate
```

只运行一次部署命令；结构已经存在时省略 `--migrate`。
仅在确实打算应用现有应用数据库结构时使用 `--migrate`。否则，脚本
要求数据库结构和 `vector` 已存在。它不会生成种子数据。
在来宾中执行的命令会调用镜像现有的 Python 应用迁移和数据库
驱动程序；**资源预配主机无需 Python 或 Azure Sandbox SDK**。
此处只执行当前的 `001_initial.sql`：创建不含工作区密钥/所有者列的结构。
`CREATE TABLE IF NOT EXISTS` 不会修改旧表；仍含旧 `owner_id` 的数据库必须另行升级，
不能仅靠重新运行初始化脚本移除该列。

执行顺序：

1. 验证现有资源组/组并解析 ACR/UAMI。拒绝使用不同区域中的组。
2. 使用托管身份从 ACR 拉取并导入全部五个镜像，逐步记录磁盘名称/ID。
3. 生成经过架构验证的 ACA 清单（JSON 也是有效的 YAML）；使用 `aca sandbox apply`
   创建五个带有唯一标签的沙箱，记录准确 ID，公开端口 8080 并获取 HTTPS URL。
4. 为每个角色交付包含全部五个地址的配置。有时限的启动闸门会阻止应用
   在所有配置和数据库检查完成之前启动。
5. 按需在 Orchestrator 来宾中执行一次迁移，然后从所有四个数据库来宾检查 `workspaces` 和 `vector` 类型。
6. 解除启动闸门。现有引导程序降权至 UID 10001，并通过 `exec` 启动该角色的 Uvicorn 进程；
   不使用依赖终端的后台进程。
7. 在**共享截止时间**内轮询全部五个 `/health` 终结点和经过身份验证的 Agent Card。验证角色、
   流式支持、JSON-RPC 版本以及准确的已公布 A2A URL。
8. 通过 Chat -> A2A -> Orchestrator -> 数据库执行只读 `GET /api/workspaces`。
   Chat 浏览器 API 免密，内部 A2A 跳转仍使用对等认证。
9. 为每个 Agent 打印一行状态/URL，并保留非敏感的部署清单。任何失败都会以
   非零退出码退出；健康检查超时不会被报告为成功。

成功输出示例（URL 仅作说明）：

```text
AGENT             STATUS       URL
chat              ready        https://<chat-ingress>
orchestrator      ready        https://<orchestrator-ingress>
data-processing   ready        https://<processing-ingress>
rag               ready        https://<rag-ingress>
sql               ready        https://<sql-ingress>
Inventory: .../.local/aca-deployment.json
```

打开 Chat URL，选择 **Session** 或通过 **New session** 创建，点击 **Connect**；无需浏览器密钥。
Session 是原有持久化工作区在界面中的名称，数据和 API 标识均保持不变。
工作区可见性不依赖部署密钥，绝不要将 A2A 密钥暴露给浏览器。
就绪表示进程、卡片、数据库检查以及只读 Chat A2A 冒烟检查已通过；这**不**
证明 Foundry 生成/嵌入、Blob 上传或全部四条业务路由可用。请另外完成
[研讨会验收流程](workshop-guide_CN.md)。

每个 ACA 操作受 `--operation-timeout` 限制（默认 900 秒）；来宾激活闸门的
时限为 3600 秒。对于缓慢或失败的设置，应调查并清理，而不是让它一直等待。
空闲自动挂起默认为 `AUTO_SUSPEND_MINS=0`（禁用），不同于 Module-04 的临时工作负载。
只有主动选择自动挂起时才设置正数 `--auto-suspend-mins`：本应用不会唤醒已挂起的工作 Agent，
Manual 激活端口在收到 HTTP/A2A 流量时会返回不可用，而不是恢复沙箱。
保持 Agent 运行会产生闲置计算费用；不用时应主动暂停，使用前恢复。
不要让活动工作流跨越空闲挂起边界。已有沙箱需要显式更新生命周期，新脚本默认值只影响新部署。
CPU/内存默认为 `SANDBOX_CPU=1000m` / `SANDBOX_MEMORY=2048Mi`。

## 失败、重试与清理

- `failed_stage=volume`：检查账户 URL、组身份、数据角色、存储网络和 CLI BYO 支持。
  同名卷若容器/身份不同，应使用新的 `KB_VOLUME_NAME`，不要删除共享卷。
  创建卷或列举失败时，在导入镜像前停止。
- `failed_stage=mount`：`failed_role` 指明来宾。检查原生挂载和 UID 10001 权限，
  不要以目录代替挂载或修改存储数据权限来绕过闸门。所有激活和就绪检查都会阻止；
  清单保留卷详情及已成功的各角色挂载检查。

- 为保留先前清单，脚本拒绝使用已有输出文件。检查
  上次尝试后，请使用新的 `--output`。**重新应用 ACA 部署会创建新磁盘镜像和沙箱**，而不是原地更新。
- 失败时会保留已知 ID、名称、唯一部署标签以及阶段/状态。如果云操作
  已完成但响应丢失，请在重试前通过记录的磁盘名称/部署标签
  查找该资源。不要假定未返回 ID 就表示未创建资源。
- 两个脚本都不会删除失败的资源、移除数据库数据、轮换凭据或更改共享
  存储网络/RBAC。models 阶段保持 Module-01 的 Foundry 授权不变，ACA 阶段可能向组中添加
  Module-01 UAMI。HorizonDB 增量部署也不会移除先前创建的防火墙规则。
- 仅检查特定清单中的五个资源。先删除这些沙箱，再删除其
  磁盘镜像。**绝不要删除共享的 Module-04 SandboxGroup 或 Module-01 资源组。**
- 对于超时的 Agent，请在记录的订阅/资源组/组/区域中，使用准确记录的 ID 执行
  `aca sandbox get` / `aca sandbox exec`。安全地检查来宾诊断信息；配置和错误可能
  包含凭据。不要将运行时配置转储到支持日志中。
- 数据库检查失败通常意味着 DNS/出站/防火墙/TLS/身份验证问题、扩展允许列表尚未应用，
  或数据库结构缺失。仅有健康的 `/health` 响应无法检测到这些问题。

## 验证证据与官方参考

Shell 回归测试套件使用桩替代 Azure 操作和 HTTP 响应，检查失败、超时和机密
处理，并且可以调用实际 ACA CLI 进行**离线清单验证**：

```bash
REAL_ACA="$(command -v aca)" bash agent-src/tests/deploy-shell.test.sh
```

Bicep 编译和离线测试不等于 Azure 部署验收。应针对实际数据库、构建镜像和五个沙箱，
另行保留部署清单及业务验收结果；不能用历史或离线结果证明当前部署可用。

- [HorizonDB 集群架构](https://learn.microsoft.com/en-us/azure/templates/microsoft.horizondb/2026-05-01-preview/clusters)
- [允许 HorizonDB 扩展](https://learn.microsoft.com/en-us/azure/horizondb/extensions/how-to-allow-extensions)
- [HorizonDB pgvector](https://learn.microsoft.com/en-us/azure/horizondb/ai/vector-search-pgvector)
- [PostgreSQL Flexible Server 资源架构](https://learn.microsoft.com/en-us/azure/templates/microsoft.dbforpostgresql/2024-08-01/flexibleservers)
- [PostgreSQL 扩展允许列表](https://learn.microsoft.com/en-us/azure/postgresql/extensions/how-to-allow-extensions)
- [PostgreSQL TLS](https://learn.microsoft.com/en-us/azure/postgresql/security/security-tls)
- [ACA 沙箱](https://sandboxes.azure.com/docs/sandboxes/sandboxes)
- [原生卷与 BYO 容器](https://sandboxes.azure.com/docs/sandboxes/volumes)
- [磁盘镜像](https://sandboxes.azure.com/docs/sandboxes/disk-images)
- [文件](https://sandboxes.azure.com/docs/sandboxes/sandbox/files)
- [端口](https://sandboxes.azure.com/docs/sandboxes/sandbox/ports)
