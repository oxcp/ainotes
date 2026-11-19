# 重建并替换 Module-06 Agent 沙箱

语言：[English](rebuild-agents.md) | **中文**

修改 Agent 代码后，可按本文删除当前五个 Module-06 沙箱，重新构建镜像，
再启动一套新的沙箱。

## 操作范围与注意事项

- 只替换 `chat`、`orchestrator`、`data-processing`、`rag` 和 `sql`。
- 保留数据库、已上传的 Blob 数据、运行时配置、共享 SandboxGroup、卷、
  资源组及 Module-04 沙箱。
- **不要为本次更新运行 [cleanup.sh](cleanup.sh)。** 完整清理还会删除
  Module-06 数据库资源、上传数据及本地配置。
- 删除沙箱是破坏性操作，会中断应用。如果需要保留来宾本地的文件或日志，
  应先创建快照。下述命令不会删除已经持久化到数据库或 Blob 存储的数据。
- ACR 构建、新沙箱及保留的磁盘/快照均可能产生费用。
- 本文假定已经有一套部署及可用的运行时配置。
  首次部署请参阅[研讨会操作指南](readme_CN.md)。

所有命令均在**同一个 Linux / WSL Bash 会话**中运行，
工作目录为包含 [deploy.sh](deploy.sh) 的本模块根目录。
需要 Bash、Azure CLI、`aca`、`jq`、`curl`、`openssl` 和 GNU `timeout`。

## 推荐：一键重建

运行[重建脚本](rebuild-agents.sh)：

```bash
bash rebuild-agents.sh
```

脚本读取旧清单和已有配置，核对云端部署/角色标签及源磁盘 ID，并列出目标。
输入 **`rebuild module-06`**，确认构建和替换操作。
随后先完成五个镜像的构建，**再删除任何旧沙箱**；删除前会再次核对归属，
只删除清单记录的沙箱，确认删除完成后调用 `deploy.sh --stage aca`。
镜像构建失败时，旧沙箱仍保持运行。
只有新清单确认五个 Agent 全部就绪且使用新标签，脚本才会报告完成。

如果需要保留来宾本地状态，请开启快照。
全部所需快照成功后，才会开始删除任何沙箱：

```bash
bash rebuild-agents.sh --snapshot
```

无人值守运行时，显式选择当前清单和配置。
**`--yes` 会跳过破坏性操作确认**，使用前务必核对目标文件：

```bash
bash rebuild-agents.sh \
  --inventory .local/aca-deployment.json \
  --config .local/aca-config.json \
  --snapshot \
  --yes
```

- `--inventory` 默认使用 `OLD_ACA_OUTPUT`，否则使用模块下的
  `.local/aca-deployment.json`。重建成功后，下次替换应指向脚本打印的新清单，
  不会自动选择最新文件。
- `--config` 默认使用 `ACA_CONFIG`，否则使用 `.local/aca-config.json`。
  运行前应恢复原有的自定义镜像仓库、公共配置、身份及网络环境变量。
- 脚本默认生成唯一镜像标签及新的 `.local/aca-deployment-rebuild-*.json` 清单，
  有意不复用已有的 `IMAGE_TAG` 和 `ACA_OUTPUT`。如需覆盖，请明确使用
  `--tag` 或 `--output`；已有输出文件会被拒绝。
  显式相对路径以调用者目录为基准，默认路径以脚本所在模块目录为基准。
- 已不存在的清单沙箱会跳过；但如果所有记录的沙箱都已不存在，脚本会拒绝继续，
  避免根据过期清单盲目再创建一套部署。清单格式错误、归属或源磁盘不匹配也会停止。
- 脚本不会调用完整清理或数据库迁移，旧清单、配置、导入磁盘及快照均保留。
  重建期间不要并行部署或清理。任何阶段失败都会停止后续步骤，不自动回滚；
  重试前应核对清单和云端实际状态。

查看全部选项，或运行不调用真实 Azure/ACA 服务的隔离离线测试：

```bash
bash rebuild-agents.sh --help
bash rebuild-agents.test.sh
```

下文为手动替代操作；脚本成功后无需再重复执行。
手动步骤按先删除、后构建排列。如需减少停机时间，可先完成步骤 3 的镜像构建，
再执行步骤 2，期间保持相同的环境变量和镜像标签。

## 1. 恢复部署上下文

将 `OLD_ACA_OUTPUT` 指向本次要替换的部署清单。下方默认值是初次部署的清单；
如果此前重建使用了其他清单文件名，请改为实际路径。
同样，应恢复原部署使用的自定义 `ACA_CONFIG`、`ACR_NAME`、`ACA_COMMON`、
身份或网络设置。

不要删除或覆盖旧清单及配置。

```bash
set -euo pipefail

OLD_ACA_OUTPUT="$PWD/.local/aca-deployment.json"
ACA_CONFIG="${ACA_CONFIG:-$PWD/.local/aca-config.json}"

SUBSCRIPTION_ID="$(jq -er '.subscription' "$OLD_ACA_OUTPUT")"
RESOURCE_GROUP="$(jq -er '.resource_group' "$OLD_ACA_OUTPUT")"
SANDBOX_GROUP_NAME="$(jq -er '.sandbox_group' "$OLD_ACA_OUTPUT")"
LOCATION="$(jq -er '.region' "$OLD_ACA_OUTPUT")"
DB_PROVIDER="$(jq -er '.chat.DB_PROVIDER // "horizondb"' "$ACA_CONFIG")"

REBUILD_ID="$(date -u +%Y%m%d-%H%M%S)"
IMAGE_TAG="rebuild-$REBUILD_ID"
ACA_OUTPUT="$PWD/.local/aca-deployment-$REBUILD_ID.json"

export OLD_ACA_OUTPUT ACA_CONFIG
export SUBSCRIPTION_ID RESOURCE_GROUP SANDBOX_GROUP_NAME LOCATION
export DB_PROVIDER IMAGE_TAG ACA_OUTPUT

aca_args=(
  --subscription "$SUBSCRIPTION_ID"
  --resource-group "$RESOURCE_GROUP"
  --sandbox-group "$SANDBOX_GROUP_NAME"
  --region "$LOCATION"
)

az account show -o none 2>/dev/null || az login
aca auth status >/dev/null 2>&1 || aca auth login
aca doctor "${aca_args[@]}"
```

确认订阅、资源组、SandboxGroup 和区域正确，并解决所有未通过的 `doctor` 检查，
然后再继续。

构建与部署共用唯一的 `IMAGE_TAG`。新的 `ACA_OUTPUT` 避免覆盖旧清单；
部署脚本会拒绝使用已经存在的输出文件。

## 2. 核对并只删除旧的五个沙箱

显示旧清单，确认每个目标都属于本次要替换的 Module-06 部署，
而不是 Module-04 或其他部署：

```bash
jq -r '.agents | to_entries[] |
  [.key, .value.sandbox_id, .value.status] | @tsv' "$OLD_ACA_OUTPUT"
```

如果来宾本地状态需要保留，删除前先为对应沙箱创建快照。
替换 ID 占位符，并为不同沙箱使用不同的快照名称：

```bash
aca sandbox snapshot "${aca_args[@]}" \
  --id "<sandbox-id>" \
  --name "before-rebuild-chat-$REBUILD_ID"
```

确认目标后，只删除下面明确列出的五个沙箱：

```bash
for role in chat orchestrator data-processing rag sql; do
  sandbox_id="$(jq -er --arg role "$role" \
    '.agents[$role].sandbox_id' "$OLD_ACA_OUTPUT")"

  printf 'Deleting %s: %s\n' "$role" "$sandbox_id"

  aca sandbox delete "${aca_args[@]}" \
    --id "$sandbox_id" \
    --yes
done
```

任何删除操作失败时，应停止并检查错误。不要忽略失败，
也不要通过删除共享 SandboxGroup 或丢弃清单来绕过问题。

## 3. 重新构建并发布五个 Agent 镜像

```bash
bash build-images.sh
```

[build-images.sh](build-images.sh) 会执行五次远程 ACR 构建，
并使用 `IMAGE_TAG` 发布镜像，无需本地 Docker 守护进程。

必须等五个镜像全部构建成功，再继续部署。
复用运行时配置不需要重新生成凭据或修改数据库。

## 4. 创建并启动五个新 Agent 沙箱

```bash
bash deploy.sh --stage aca
```

这个阶段会导入已经发布的镜像、创建五个新沙箱、复用配置和存储，
并检查健康端点及 Agent 连通性，不会原地更新旧沙箱。

本文所述仅代码更新不需要改变数据库结构，因此**不要追加 `--migrate`**。
如果其他更新引入了数据库迁移，应单独审核并明确执行，
不能假定本文步骤已经涵盖这些迁移。

部署应以五个 Agent 全部显示 `ready` 结束。
获取新的 Chat URL：

```bash
jq -r '.agents.chat.url' "$ACA_OUTPUT"
```

打开**新的 Chat URL**，提交新的问题，验证更新后的行为。
已有数据库和 Blob 数据仍可访问，无需重新上传。
浏览器本地对话历史按站点来源隔离，可能不会出现在新 URL 下；
它与服务端持久化数据是两回事。

## 清单、失败处理与保留资源

- 保留新旧两份清单。旧清单用于识别上次部署的资源；
  新清单记录本次沙箱 ID、镜像引用及 URL。
- 保留 `.local` 中已有的受保护配置及相关文件，不要在本流程中清空该目录。
- 构建或部署失败时，检查报告的阶段并保留对应清单。
  失败的部署可能已经创建了计费资源；重试前先核对，
  另一次部署需要新的 `ACA_OUTPUT`。
- 上述命令只删除旧沙箱，**不会删除对应的导入磁盘或快照**。
  保留的磁盘/快照仍可能产生存储费用。确认新部署正常后，
  再根据旧清单，只清理能够确定归属于旧部署的资源。
- 清理旧沙箱资源时，不要删除共享 SandboxGroup、卷、数据库、Blob 容器或资源组。

部署选项和故障排查请参阅
[CLI 部署参考](agent-src/docs/cli-deployment_CN.md)。
