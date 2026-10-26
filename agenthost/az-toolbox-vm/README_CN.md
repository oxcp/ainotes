# Azure Linux 工具箱虚拟机

[English](./README.md)

[![部署到 Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Foxcp%2Fainotes%2Fmain%2Fagenthost%2Faz-toolbox-vm%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Foxcp%2Fainotes%2Fmain%2Fagenthost%2Faz-toolbox-vm%2FuiFormDefinition.json)

使用 Bicep 或 Azure 门户自定义部署，部署一台 Ubuntu 24.04 LTS 工程工作站。`main.bicep` 是基础设施的唯一权威来源；`main.json` 由其生成，包含 cloud-init 和验证脚本。部署按钮会从 GitHub 同时加载 `main.json` 和 `uiFormDefinition.json`，显示自定义部署表单，无需单独托管安装脚本。

## 架构

```text
资源组
  新建 VNet / 子网 / NSG，或使用已有 VNet / 子网
    NIC -- 可选的 Standard 静态公共 IPv4
      Ubuntu 24.04 VM / 系统分配的托管标识
        cloud-init -> 系统工具 + 管理员用户扩展 -> 验证
```

使用的镜像为 `Canonical:ubuntu-24_04-lts:server:latest`（x64，第 2 代）。模板只创建本研讨会的操作VM，不会创建 AKS 群集、Container Apps 环境等本Workshop中其它module的内容。

安装的工具：

| 组件 | 安装方式 |
| --- | --- |
| Azure CLI | Microsoft 当前稳定版本，并检查是否满足最低版本 2.80.0 |
| Git、curl、jq | Ubuntu 软件包 |
| Azure Developer CLI（`azd`） | Microsoft 当前稳定版本 |
| Microsoft Foundry 扩展 | `microsoft.foundry`，为配置的管理员用户安装 |
| kubectl | 通过 `az aks install-cli` 安装到 `/usr/local/bin`（同时安装配套的 kubelogin） |
| Container Apps 扩展 | 使用 `--upgrade --allow-preview true` 为管理员用户安装 |

## 前提条件

- 拥有 Azure 订阅，以及在目标资源组中部署计算和网络资源（包括系统分配的标识）的权限。
- 所选 x64 第 2 代 VM 大小在目标区域具有足够的配额和容量；默认大小为 `Standard_D4s_v5`。
- 使用已有子网时，需要读取其 VNet/子网以及执行 `Microsoft.Network/virtualNetworks/subnets/join/action` 的权限，包括网络位于其他资源组的情况。
- 选择认证方式：**SSH 公钥**（默认，推荐）或**用户名/密码**。密码认证无需生成密钥，也不需要已有 Linux 环境。使用公钥认证时，仅提供公钥，将私钥保留在客户端；为兼容 Azure Linux VM 预配，请使用 4096 位 RSA 密钥。
- 为公共 SSH 访问提供受信任的源公共 IP/CIDR。默认值 `*` 仅适用于短期实验环境；部署前请将其替换。
- 首次启动期间，需要通过出站 DNS 和 HTTPS 访问 Ubuntu 软件源、Microsoft 软件包和安装端点、azd 扩展注册表，以及 GitHub/Kubernetes 下载端点。

### 如何选择认证方式

模板支持以下两种方式，默认仍为 SSH 公钥认证，以保留原有行为。两种方式都通过 SSH 连接 Linux VM，都不要求客户端已安装 Linux 或 WSL。

推荐使用下文的[自定义部署表单](#azure-门户部署)：界面只显示所选认证方式的凭据输入框，未选中的凭据会自动传为空，无需手动清空。下表中的“留空”操作仅适用于 CLI 或只加载 `main.json` 的普通参数页。

| 方式 | 适用场景 | 模板参数 |
| --- | --- | --- |
| SSH 公钥（默认，推荐） | 优先考虑安全性，或计划长期使用 VM | `authenticationType=sshPublicKey`，填写 `sshPublicKey`，将 `adminPassword` 留空 |
| 用户名/密码（可选） | 希望快速开始研讨会，不想生成或管理密钥 | `authenticationType=password`，填写 `adminPassword`，将 `sshPublicKey` 留空 |

密码方式使用 `adminUsername` 和 `adminPassword` 登录，仍需要 SSH 客户端，但不需要 `ssh-keygen`。Windows 用户可以使用系统的 **OpenSSH 客户端**；如果 PowerShell 中找不到 `ssh` 或 `ssh-keygen`，请从 Windows“可选功能”安装 **OpenSSH 客户端**，不需要安装 OpenSSH 服务端。

### 使用用户名/密码

设置 `authenticationType=password`，填写 `adminPassword`；自定义表单会自动隐藏公钥输入框并将 `sshPublicKey` 传为空。使用 CLI 或普通参数页时，请自行将 `sshPublicKey` 留空。请使用独立的 12–72 位密码，至少包含大写字母、小写字母、数字、特殊字符这四类中的三类。Azure 会在部署时验证所提供的凭据；不要将所选认证方式必需的凭据留空。

密码通过 ARM 安全字符串参数传递，不会嵌入 cloud-init 或部署输出。密码认证仅在显式选择 `password` 时启用，cloud-init 会同步配置 SSH 密码登录。新建网络时，请将 `sshAllowedSource` 限制为自己的公共 IP/CIDR（单个 IPv4 地址使用 `/32`）；已有网络需在其已有 NSG 规则中实施相同限制，不要向 `*` 开放密码登录。

### 使用 SSH 公钥：无需已有 Linux 环境

可以任选以下一种方式准备密钥：

**方式 A：在 Azure 门户生成密钥。** 在 **SSH 密钥（SSH keys）**服务中生成 RSA 密钥对，下载并妥善保存私钥，然后复制该资源的公钥，粘贴到模板的 `sshPublicKey`。此方式无需在本地运行 `ssh-keygen`，但连接 VM 时仍需 SSH 客户端和下载的私钥。

**方式 B：在 Windows PowerShell 中生成密钥。** Windows OpenSSH 客户端同时提供 `ssh` 和 `ssh-keygen`。在 PowerShell 中运行以下命令；私钥保存在用户主目录，而不是存储库中：

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
ssh-keygen -t rsa -b 4096 -f "$env:USERPROFILE\.ssh\toolbox_rsa"
Get-Content "$env:USERPROFILE\.ssh\toolbox_rsa.pub"
```

按提示设置私钥口令，并将最后一条命令显示的完整公钥复制到 `sshPublicKey`。不要上传私钥。如果该文件名已存在，请选择其他名称，不要覆盖已有密钥。

**方式 C：在 Linux、WSL 或 Azure Cloud Shell 中生成密钥。** 在所选环境中运行：

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/toolbox_rsa
```

将生成的 `~/.ssh/toolbox_rsa.pub` 的完整内容填入 `sshPublicKey`，并将私钥保留在用于连接 VM 的客户端；使用 Cloud Shell 时，请在会话结束前确保私钥已安全保存。

## 参数

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `location` | 资源组所在区域 | 资源区域 |
| `vmName` | `azure-toolbox-vm` | VM 名称及由其派生的资源名称 |
| `adminUsername` | `azureuser` | SSH 用户和用户范围扩展的所有者 |
| `vmSize` | `Standard_D4s_v5` | 兼容 x64 第 2 代的 VM 大小 |
| `authenticationType` | `sshPublicKey` | `sshPublicKey` 或 `password` |
| `sshPublicKey` | 空 | 完整的公钥文本；使用 `sshPublicKey` 认证时必填 |
| `adminPassword` | 空 | 安全字符串；使用 `password` 认证时必填，否则留空 |
| `createPublicIp` | `true` | 关联公共 IPv4 地址 |
| `networkMode` | `new` | `new` 新建 VNet/子网；`existing` 关联已有子网 |
| `existingSubnetResourceId` | 空 | 完整的子网资源 ID；`networkMode=existing` 时必填 |
| `sshAllowedSource` | 有公共 IP 时为 `*`，否则为 `VirtualNetwork` | 仅新建网络：SSH 源 IP/CIDR 或服务标记 |
| `vnetName` | `vnet-toolbox` | 仅新建网络：VNet 名称 |
| `vnetAddressPrefix` | `10.10.0.0/16` | 仅新建网络：VNet 地址空间 |
| `subnetName` | `default` | 仅新建网络：子网名称 |
| `subnetAddressPrefix` | `10.10.0.0/24` | 仅新建网络：VNet 内的子网地址范围 |
| `existingNatGatewayResourceId` | 空 | 仅新建网络：可选的现有 NAT 网关，用于显式出站访问 |

请使用有效的 Azure 资源名称，以及有效的 Linux 管理员用户名和主机名。新建网络时，选择互不重叠的地址范围和唯一的 VNet 名称：该模式会创建并管理 VNet/子网，不要将其指向共享 VNet。在同一资源组中进行多次部署时，请为 `vmName` 选择唯一值；新建网络时，还需使用唯一的 `vnetName`。

### 选择新建或已有网络

- **新建 VNet 和子网**（`networkMode=new`，默认）：创建 VNet、子网和 NSG。在 **Network mode** 中选择 **Create a new VNet and subnet**，然后在专用文本框中填写 VNet/子网名称和 CIDR。**New subnet name** 默认是 `default`，可以自行修改。可以选择关联已有 NAT 网关。
- **使用已有 VNet 和已有子网**（`networkMode=existing`）：在 **Network mode** 中选择 **Use an existing VNet and subnet**。**Existing VNet** 选择器仅列出已有网络；**Existing subnet** 下拉框通过该 VNet 的子网 API 加载，只列出已有子网，没有新建选项。所有新建网络输入框均隐藏。表单将所选子网的完整资源 ID 作为 `existingSubnetResourceId`，其中包含网络所在资源组，该资源组可以与 VM 不同。NIC 加入该子网；模板不创建 VNet、子网或 NSG，不修改已有子网的 NSG、路由、NAT 或默认出站访问配置，也不会向 NIC 添加 NSG。

已有 VNet 必须与 VM 位于同一订阅和区域。请选择兼容 VM NIC 且至少有一个可用地址的 IPv4 子网，不要使用保留的服务专用子网或不兼容的委派子网。你需要自行确保已有网络安全规则仅允许可信来源访问 TCP/22，且出站 DNS/HTTPS 可访问首次启动所需的下载端点。选择公共 IP 不会绕过已有子网的安全或路由规则。已有网络模式会忽略 `sshAllowedSource`、`existingNatGatewayResourceId` 等仅用于新建网络的参数，它们不会配置访问或出站连接。

使用 CLI 或普通参数页时，设置 `networkMode=existing` 并提供完整子网资源 ID，格式为 `/subscriptions/<subscription-id>/resourceGroups/<network-resource-group>/providers/Microsoft.Network/virtualNetworks/<vnet-name>/subnets/<subnet-name>`，不要留空。不支持在已有 VNet 中新建子网。

### 仅专用网络与入站访问

设置 `createPublicIp=false` 时，不会部署公共 IP 资源，也不会在 NIC 上关联公共 IP，公共 IP 输出为空字符串。SSH 需要现有的专用路由，例如单独建立的对等互连/VPN 或 Bastion 连接。设置 SSH 源不会创建该路由。

新建网络时，NSG 仅允许来自 `sshAllowedSource` 的 TCP/22 入站流量，包括原本默认允许的 VNet 范围内入站流量，并显式拒绝其他入站流量。默认出站 NSG 规则保持启用。已有网络保留原有安全与出站配置，需要单独确认。

## Azure 门户部署

### 推荐：通过 GitHub 部署按钮加载自定义表单

`main.json` 负责部署资源；配套的 [uiFormDefinition.json](./uiFormDefinition.json) 负责界面。仅导入 `main.json` 的普通“部署自定义模板”页面无法动态隐藏参数，必须同时加载自定义表单。

1. 点击本 README 顶部的 **部署到 Azure** 按钮并登录 Azure。
2. Azure 门户会直接从公开 GitHub 仓库加载资源模板和自定义表单，无需下载文件、安装 CLI、在 sandbox 粘贴代码或发布 Template Spec。
3. 按下文说明填写 **Basics**、**Administrator login** 和 **Networking**。检查配置后选择 **Create**，实际创建资源。

按钮引用仓库 `main` 分支上的两份文件。分享按钮前，请先提交并推送生成的 `main.json` 及与之匹配的 `uiFormDefinition.json`；本地或未推送的修改不会被加载。如果门户提示无法加载文件，请确认两个 GitHub Raw URL 均可访问且指向预期版本。正式研讨会需要固定版本时，将两个 URL 中的 `main` 替换为同一个 Git 标签或提交 ID，再对完整 Raw URL 进行 URL 编码。不要在链接或 GitHub 中放入凭据。

### 备用：在 Form view sandbox 中预览本地修改

尚未推送到 GitHub 的文件可以使用以下方式测试，无需预先安装 CLI：

1. 将此目录的 `main.json` 和 `uiFormDefinition.json` 保存到本地。
2. 打开 [Azure 门户 Form view sandbox](https://aka.ms/form/sandbox)，登录 Azure，将 **Package Type** 设置为 **CustomTemplate**。
3. 在 **Deployment template (optional)** 中加载 `main.json`。如果提示覆盖当前更改，选择 **Yes**；此时生成的是普通表单。
4. 将代码编辑区中的整个表单 JSON 替换为本目录 `uiFormDefinition.json` 的完整内容，然后选择 **Preview**。
5. 在 **Basics** 中选择订阅、资源组、区域、VM 名称和大小。
6. 在 **Administrator login** 中填写用户名并选择认证方式：
   - **SSH public key (recommended)**：只显示 SSH 公钥输入框，不显示密码框。
   - **Username and password**：只显示密码和确认密码框，不显示 SSH 公钥框。
   - 即使先填写一种凭据再切换，未选中的凭据也会自动传为空。
7. 在 **Networking** 中选择**新建**或**已有** VNet：
   - 选择 **Create a new VNet and subnet**，显示新 VNet 名称/CIDR 和子网名称/CIDR 输入框。在 **New subnet name** 中填写所需子网名称。填写可信 SSH 来源，并可选填已有 NAT 网关。SSH 来源必填且不能为 `*`；私有连接可填写专用源 CIDR 或 `VirtualNetwork`。
   - 选择 **Use an existing VNet and subnet**，在 **Existing VNet** 中选定已有网络，再从 **Existing subnet** 下拉框中选择已有子网。此模式使用独立的已有资源选择控件，不使用混合创建/选择控件；所有新建网络输入框均隐藏，不提供新建子网操作。如果子网列表为空或加载失败，请检查所选 VNet 的子网以及网络读取权限。请自行确认其安全规则、路由和出站访问。
   - 选择是否关联公共 IP。界面不提供在已有 VNet 中新建子网的选项。
8. 检查配置后选择 **Review + create** / **Create** 完成部署。注意：sandbox 的 **Preview** 不是模拟部署，点击 **Create** 会实际创建 Azure 资源并产生费用。

如需为团队提供可重复使用的入口，可由管理员通过 Azure CLI 将模板和表单一起发布为 Template Spec，然后在门户打开该 Template Spec 并选择 **Deploy**。以下命令只发布模板规范，不会部署 VM；请替换资源组、位置和版本：

```bash
az ts create \
  --name toolbox-vm \
  --version 1.0 \
  --resource-group YOUR_TEMPLATE_SPEC_RESOURCE_GROUP \
  --location YOUR_AZURE_REGION \
  --template-file main.json \
  --ui-form-definition uiFormDefinition.json
```

该命令需在本目录运行，并具有 Template Spec 发布权限；部署用户需能读取该 Template Spec，且拥有部署 VM 所需的权限。更新 `main.json` 的参数时，也要同步更新 `uiFormDefinition.json`。表单中的 `outputs.parameters` 只是部署参数映射，不是部署结果输出；密码仍传入模板的 `secureString` 参数。

### 备用：只导入资源模板（会同时显示两个凭据参数）

如果继续使用以下普通导入方式，公钥和密码参数仍会同时显示，需手动将未使用的凭据留空。需要自动切换显示时，请使用上面的自定义表单。

1. 打开 Azure 门户，搜索 **部署自定义模板（Deploy a custom template）**。
2. 选择 **在编辑器中生成自己的模板（Build your own template in the editor）**。
3. 选择 **加载文件（Load file）**，加载此目录中生成的 `main.json`。
4. 选择 **保存（Save）**。
5. 选择订阅和资源组，然后检查部署参数。保持 `networkMode=new` 可新建网络；或设置 `networkMode=existing` 并填写 `existingSubnetResourceId` 使用已有子网。已有模式下，新建网络相关参数不生效。
6. 选择 `authenticationType`：使用 `sshPublicKey` 时，将完整的 SSH **公钥**粘贴到 `sshPublicKey`，并将 `adminPassword` 留空；使用 `password` 时，填写 `adminPassword`，并将 `sshPublicKey` 留空。新建网络时，将 `sshAllowedSource` 设置为受信任的公共 IP/CIDR，不要使用 `*`，尤其是在使用密码时；使用已有子网时，确认其已有 NSG 规则实施相同限制。根据需要更改管理员用户名或其他参数。下图展示公钥认证示例；更新后的模板还包含认证方式和网络选择参数：
![在 Azure 门户中部署工具箱 VM](../pic/toolbox-vm-deployment.png)

7. 选择 **查看 + 创建（Review + create）**，验证成功后选择 **创建（Create）**。
8. 从部署输出中获取 VM 名称、资源 ID、专用/公共地址和管理员用户名。

Azure 部署成功仅表示 VM 已完成预配，**并不表示** cloud-init 已完成工具安装。请按下文说明等待并验证。

## 验证

使用部署输出中的地址和配置的用户名通过 SSH 连接（如修改了用户名，请替换 `azureuser`）。Windows 用户可以在 PowerShell 中使用 Windows OpenSSH 客户端运行以下命令，无需 WSL。如果没有 `ssh` 命令，请从 Windows“可选功能”安装 **OpenSSH 客户端**。

使用密码认证时，运行以下命令，并在提示时输入密码（不要将密码写入命令）：

```bash
ssh azureuser@VM_IP_ADDRESS
```

使用公钥认证时，指定下载或本地生成的私钥：

```bash
ssh -i ~/.ssh/toolbox_rsa azureuser@VM_IP_ADDRESS
```

Windows PowerShell 使用以下路径形式（如果私钥从门户下载，请替换为实际下载路径）：

```powershell
ssh -i "$env:USERPROFILE\.ssh\toolbox_rsa" azureuser@VM_IP_ADDRESS
```

首次连接时，核对目标 VM 的主机密钥指纹后再接受提示。如果设置了私钥口令，公钥认证时输入的是私钥口令，而不是 VM 用户密码。连接成功后，下面的 Linux 命令均在远程 VM 中执行，不是在本地 PowerShell 中执行。

在 VM 上等待初始化完成，然后以 **azureuser**（或配置的管理员用户）身份验证，不要使用 sudo：

```bash
cloud-init status --wait
/usr/local/bin/verify-tools.sh
test -f /var/lib/toolbox-install-complete && echo "READY" || echo "NOT READY"
```

## 故障排查

> [!tip]
> 本部分内容仅用于安装toolbox VM出现问题时的排查参考。如果toolbox VM安装成功，请忽略本章节内容。

在 VM 上运行：

```bash
cloud-init status --long
sudo less /var/log/cloud-init-output.log
sudo less /var/log/toolbox-install.log
sudo cat /var/log/toolbox-versions.log
test -f /var/lib/toolbox-install-complete && echo "READY" || echo "NOT READY"
```

`/var/log/cloud-init-output.log` 包含可能发生在工具箱安装程序启动前的软件包阶段错误。`/var/log/toolbox-install.log` 记录安装进度和错误。缺少报告或标记表示验证尚未成功完成。如果无法通过 SSH 连接，请在 VM 的门户页面中使用托管启动诊断。

如果 SSH 连接失败，请检查用户名、所选认证方式对应的密码或匹配的私钥、公共/专用地址、NSG 源 CIDR 和专用路由。如果安装失败，请检查 DNS/HTTPS 出站访问、Azure Policy、上游软件包/扩展的可用性，以及日志中的第一个错误。

修复安装问题后，**仅在 cloud-init 完成后**重新运行：

```bash
sudo bash /usr/local/sbin/install-toolbox.sh
/usr/local/bin/verify-tools.sh
```

安装程序会刷新基础软件包，安装当前稳定版 CLI，安装或升级 Foundry，在允许预览版本的情况下升级 Container Apps，重新安装 kubectl，并重新验证。它不会重复添加 profile 条目。不要并发运行多个安装程序。重试安装程序不会清除先前的 cloud-init 错误状态；请单独检查新日志和标记。除非打算重新执行所有首次启动处理，否则不要在已部署的 VM 上运行 `cloud-init clean`。

## 安全与生命周期

- 默认禁用 SSH 密码登录，仅在 `authenticationType=password` 时启用。密码通过 ARM `secureString` 参数传递，不会嵌入 cloud-init 或部署输出。不要提交私钥、密码、令牌或包含凭据的参数文件。
- 将公共 SSH 访问限制为受信任的 CIDR。对于长期使用的环境，优先采用仅专用网络 VM，并配合现有专用路由和显式 NAT 出站访问。
- 工具二进制文件安装在系统范围内。Azure CLI 和 azd 扩展配置在所选管理员用户的主目录中，而不仅是 `/root`；其他用户必须配置自己的扩展。
- 安装程序通过 HTTPS 下载 Microsoft 官方脚本，并以 root 身份执行。请根据环境要求审查上游安装程序和网络需求；工具版本有意跟随当前稳定版本，因此重新构建无法保证逐比特一致。
- 不会执行无人值守的完整操作系统升级。请根据运维策略维护操作系统安全补丁和工具更新。
- 更改源文件或重新部署不会在现有 VM 上重新运行 cloud-init。重新部署不是工具升级机制；请根据情况重试安装程序或重新创建 VM。
- VM 计算资源、磁盘和可选的公共 IP 会产生费用。
