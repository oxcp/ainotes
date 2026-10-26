# Azure Linux 工具箱虚拟机

使用 Bicep 或 Azure 门户自定义部署，部署一台 Ubuntu 24.04 LTS 工程工作站。`main.bicep` 是基础设施的唯一权威来源；`main.json` 由其生成，包含 cloud-init 和验证脚本。通过门户部署时只需要 `main.json`，无需单独托管脚本。

## 架构

```text
资源组
  VNet / 子网 / NSG
    NIC -- 可选的 Standard 静态公共 IPv4
      Ubuntu 24.04 VM / 系统分配的托管标识
        cloud-init -> 系统工具 + 管理员用户扩展 -> 验证
```

使用的镜像为 `Canonical:ubuntu-24_04-lts:server:latest`（x64，第 2 代）。模板不会创建 AKS 群集、Container Apps 环境、容器注册表、存储帐户、Key Vault 或 Foundry 项目，也不会分配任何 RBAC 角色。启动诊断使用平台管理的存储。

安装的工具：

| 组件 | 安装方式 |
| --- | --- |
| Azure CLI | Microsoft 当前稳定版本，并检查是否满足最低版本 2.80.0 |
| Git、curl、jq | Ubuntu 软件包 |
| Azure Developer CLI（`azd`） | Microsoft 当前稳定版本 |
| Microsoft Foundry 扩展 | `microsoft.foundry`，为配置的管理员用户安装 |
| kubectl | 通过 `az aks install-cli` 安装到 `/usr/local/bin`（同时安装配套的 kubelogin） |
| Container Apps 扩展 | 使用 `--upgrade --allow-preview true` 为管理员用户安装 |

[AKS Pod 沙盒](https://learn.microsoft.com/azure/aks/use-pod-sandboxing)目前需要 Azure CLI 2.80.0+ 和 kubectl，不需要 `aks-preview` 或单独的沙盒扩展。验证会检查 `az aks create` 是否提供 `--workload-runtime`。Ubuntu VM 是管理客户端；沙盒化的 AKS 节点池本身需要使用 Azure Linux。虽然基础设施 API 和 CLI 安装程序是稳定版，但 Foundry 扩展和部分 Container Apps 命令可能处于预览阶段。允许使用 Container Apps 预览版本，并不意味着在当前版本为稳定版时强制使用预览版。

## 前提条件

- 拥有 Azure 订阅，以及在目标资源组中部署计算和网络资源（包括系统分配的标识）的权限。
- 所选 x64 第 2 代 VM 大小在目标区域具有足够的配额和容量；默认大小为 `Standard_D4s_v5`。
- 拥有 SSH 密钥对。仅提供公钥；将私钥保留在客户端。Azure Linux VM 公钥预配支持 RSA SSH 密钥；为确保兼容性，请使用 4096 位 RSA 密钥。
- 为公共 SSH 访问提供受信任的源公共 IP/CIDR。默认值 `*` 仅适用于短期实验环境；部署前请将其替换。
- 使用 CLI 部署或重新生成模板时，需要 Azure CLI、Bicep CLI 和这些源文件。使用 `az login` 登录，并另行选择订阅。
- 首次启动期间，需要通过出站 DNS 和 HTTPS 访问 Ubuntu 软件源、Microsoft 软件包和安装端点、azd 扩展注册表，以及 GitHub/Kubernetes 下载端点。

如有需要，请创建密钥（在客户端上操作，不要在存储库中创建）：

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/toolbox_rsa
```

## 参数

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `location` | 资源组所在区域 | 资源区域 |
| `vmName` | `azure-toolbox-vm` | VM 名称及由其派生的资源名称 |
| `adminUsername` | `azureuser` | SSH 用户和用户范围扩展的所有者 |
| `vmSize` | `Standard_D4s_v5` | 兼容 x64 第 2 代的 VM 大小 |
| `sshPublicKey` | 必填 | 完整的公钥文本 |
| `createPublicIp` | `true` | 关联公共 IPv4 地址 |
| `sshAllowedSource` | 有公共 IP 时为 `*`，否则为 `VirtualNetwork` | SSH 源 IP/CIDR 或服务标记 |
| `vnetName` | `vnet-toolbox` | 新 VNet 的名称 |
| `vnetAddressPrefix` | `10.10.0.0/16` | VNet 地址空间 |
| `subnetName` | `default` | 新子网的名称 |
| `subnetAddressPrefix` | `10.10.0.0/24` | VNet 内的子网地址范围 |
| `existingNatGatewayResourceId` | 空 | 可选的现有 NAT 网关，用于显式出站访问 |

请使用有效的 Azure 资源名称，以及有效的 Linux 管理员用户名和主机名。选择互不重叠的网络地址范围。此模板拥有并管理 VNet 和子网：请使用唯一名称，不要将其指向共享 VNet。在同一资源组中进行多次部署时，请为 `vmName` 和 `vnetName` 选择唯一值。

### 仅专用网络与出站访问

设置 `createPublicIp=false` 时，不会部署公共 IP 资源，也不会在 NIC 上关联公共 IP，公共 IP 输出为空字符串。SSH 需要现有的专用路由，例如单独建立的对等互连/VPN 或 Bastion 连接。设置 SSH 源不会创建该路由。

对于不使用 NAT 网关的最简仅专用网络实验环境，子网会显式启用 Azure 默认出站访问（`defaultOutboundAccess=true`），使首次启动时无需创建额外基础设施即可下载所需内容。这是一种隐式、非确定性的出站访问方式，不代表关联了公共 IP 或建立了入站路径。不建议在生产环境中使用此配置；Azure 在较新的 API 中已将新子网默认为专用子网。请参阅[默认出站访问](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access)。

如需可预测的生产环境出站访问，请通过 `existingNatGatewayResourceId` 提供同一区域内兼容的 NAT 网关，该网关需已配置公共 IP/前缀，并具有可用的子网关联容量。模板会关联该网关，但不会创建或管理它。当提供 NAT 网关或 VM 自身具有公共 IP 时，子网会禁用默认出站访问。部署前，请确保策略允许所选配置；如果仅专用网络部署不允许默认出站访问，则必须使用现有 NAT 网关。

NSG 仅允许来自 `sshAllowedSource` 的 TCP/22 流量，并显式拒绝其他入站流量，包括原本默认允许的 VNet 范围内入站流量。默认出站 NSG 规则保持启用，以便完成安装。

## Azure 门户部署

1. 打开 Azure 门户，搜索 **部署自定义模板（Deploy a custom template）**。
2. 选择 **在编辑器中生成自己的模板（Build your own template in the editor）**。
3. 选择 **加载文件（Load file）**，加载此目录中生成的 `main.json`。
4. 选择 **保存（Save）**。
5. 选择订阅和资源组，然后检查部署参数。
6. 将完整的 SSH **公钥**粘贴到 `sshPublicKey`；将 `sshAllowedSource` 设置为受信任的公共 IP/CIDR。根据需要更改管理员用户名或其他参数。参考以下的参数输入示例：
![在 Azure 门户中部署工具箱 VM](../pic/toolbox-vm-deployment.png)

7. 选择 **查看 + 创建（Review + create）**，验证成功后选择 **创建（Create）**。
8. 从部署输出中获取 VM 名称、资源 ID、专用/公共地址和管理员用户名。

Azure 部署成功仅表示 VM 已完成预配，**并不表示** cloud-init 已完成工具安装。请按下文说明等待并验证。

## Azure CLI 部署

以下示例使用 Bash（包括 Azure Cloud Shell）。请将资源组和源 CIDR 替换为自己的值；模板中未内嵌订阅或资源组。

```bash
RESOURCE_GROUP='your-resource-group'
SSH_SOURCE='your-trusted-public-ip/32'

az deployment group create \
  --name toolbox \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file main.bicep \
  --parameters sshPublicKey="$(cat ~/.ssh/toolbox_rsa.pub)" \
               sshAllowedSource="${SSH_SOURCE}"
```

对于使用显式出站 NAT 的仅专用网络 VM：

```bash
az deployment group create \
  --name toolbox \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file main.bicep \
  --parameters sshPublicKey="$(cat ~/.ssh/toolbox_rsa.pub)" \
               createPublicIp=false \
               sshAllowedSource='10.20.0.0/24' \
               existingNatGatewayResourceId="${NAT_GATEWAY_RESOURCE_ID}"
```

`NAT_GATEWAY_RESOURCE_ID` 必须指向已配置好的现有 NAT 网关。仅在使用上述实验环境默认出站访问方式时，才可省略此参数。请先单独配置专用路由，再尝试通过 SSH 连接。

查看输出：

```bash
az deployment group show \
  --name toolbox \
  --resource-group "${RESOURCE_GROUP}" \
  --query properties.outputs --output json
```

## 重新生成门户模板

更改 Bicep、cloud-init 或 `scripts/verify-tools.sh` 后，运行：

```bash
az bicep build \
  --file main.bicep \
  --outfile main.json
```

将重新生成的 `main.json` 与其源文件一起提交。不要手动编辑其中的基础设施逻辑。Bicep 会嵌入 cloud-init 和唯一验证脚本源文件的 Base64 副本。它还会将配置的用户名以 Base64 编码写入数据文件，而不是将其插入 shell 命令。

## 验证

使用部署输出中的地址和配置的用户名通过 SSH 连接：

```bash
ssh -i ~/.ssh/toolbox_rsa azureuser@VM_IP_ADDRESS
```

在 VM 上等待初始化完成，然后以**普通管理员用户**身份验证，不要使用 sudo：

```bash
cloud-init status --wait
/usr/local/bin/verify-tools.sh
test -f /var/lib/toolbox-install-complete && echo "READY" || echo "NOT READY"
```

如果已将存储库复制到 VM，也可以运行 `bash scripts/verify-tools.sh`。验证会显示工具版本，检查 Azure CLI 最低版本要求，检查 AKS 沙盒 CLI 选项，并要求当前用户已安装两个扩展。验证不需要登录 Azure，也不需要正在运行的群集。列出 azd 扩展时仍可能需要访问扩展注册表。

查看自动生成的版本报告：

```bash
sudo cat /var/log/toolbox-versions.log
```

只有在必需的安装和验证均成功后，才会创建完成标记。重试前，安装程序会删除旧标记和旧报告。失败时不会创建成功标记，但验证失败可能留下不完整的版本报告。

也可以从客户端检查基础设施配置：

```bash
az vm show --resource-group "${RESOURCE_GROUP}" --name azure-toolbox-vm \
  --query '{image:storageProfile.imageReference,passwordDisabled:osProfile.linuxConfiguration.disablePasswordAuthentication,identity:identity.type}' \
  --output json
```

SSH 登录、cloud-init 就绪状态和实际工具安装情况都必须在已部署的 VM 上检查；仅编译模板无法证明这些运行时结果。

## 故障排查

在 VM 上运行：

```bash
cloud-init status --long
sudo less /var/log/cloud-init-output.log
sudo less /var/log/toolbox-install.log
sudo cat /var/log/toolbox-versions.log
test -f /var/lib/toolbox-install-complete && echo "READY" || echo "NOT READY"
```

`/var/log/cloud-init-output.log` 包含可能发生在工具箱安装程序启动前的软件包阶段错误。`/var/log/toolbox-install.log` 记录安装进度和错误。缺少报告或标记表示验证尚未成功完成。如果无法通过 SSH 连接，请在 VM 的门户页面中使用托管启动诊断。

如果 SSH 连接失败，请检查用户名、匹配的私钥、公共/专用地址、NSG 源 CIDR 和专用路由。如果安装失败，请检查 DNS/HTTPS 出站访问、Azure Policy、上游软件包/扩展的可用性，以及日志中的第一个错误。

修复安装问题后，**仅在 cloud-init 完成后**重新运行：

```bash
sudo bash /usr/local/sbin/install-toolbox.sh
/usr/local/bin/verify-tools.sh
```

安装程序会刷新基础软件包，安装当前稳定版 CLI，安装或升级 Foundry，在允许预览版本的情况下升级 Container Apps，重新安装 kubectl，并重新验证。它不会重复添加 profile 条目。不要并发运行多个安装程序。重试安装程序不会清除先前的 cloud-init 错误状态；请单独检查新日志和标记。除非打算重新执行所有首次启动处理，否则不要在已部署的 VM 上运行 `cloud-init clean`。

## 安全与生命周期

- SSH 密码登录已禁用；不要提交私钥、密码、令牌或其他凭据。
- 将公共 SSH 访问限制为受信任的 CIDR。对于长期使用的环境，优先采用仅专用网络 VM，并配合现有专用路由和显式 NAT 出站访问。
- 工具二进制文件安装在系统范围内。Azure CLI 和 azd 扩展配置在所选管理员用户的主目录中，而不仅是 `/root`；其他用户必须配置自己的扩展。
- 系统分配的托管标识没有任何 RBAC 角色分配。授权操作员必须另行在最小范围内授予所需的最低权限角色，之后 `az login --identity` 才能访问 Azure 资源。
- 安装程序通过 HTTPS 下载 Microsoft 官方脚本，并以 root 身份执行。请根据环境要求审查上游安装程序和网络需求；工具版本有意跟随当前稳定版本，因此重新构建无法保证逐比特一致。
- 不会执行无人值守的完整操作系统升级。请根据运维策略维护操作系统安全补丁和工具更新。
- 更改源文件或重新部署不会在现有 VM 上重新运行 cloud-init。重新部署不是工具升级机制；请根据情况重试安装程序或重新创建 VM。Azure 也限制对现有 VM 自定义数据的更改。
- VM 计算资源、磁盘和可选的公共 IP 会产生费用。不再需要时，请仅删除此部署拥有的资源；不要删除共享资源组或单独管理的 NAT 网关。
