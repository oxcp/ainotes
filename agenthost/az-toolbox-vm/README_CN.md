# Azure Linux 工具箱虚拟机

> 🌐 语言 / Language: [English](README.md) | **中文**


使用 Bicep 或 Azure 门户自定义部署，部署一台 Ubuntu 24.04 LTS 工程工作站，其中预装了本研讨会所需的工具。

## 前提条件

- 拥有 Azure 订阅，以及在目标资源组中部署计算和网络资源（包括系统分配的标识）的权限。
- 所选 x64 第 2 代 VM 大小在目标区域具有足够的配额和容量；默认大小为 `Standard_D4s_v5`。
- 使用已有子网时，需要读取其 VNet/子网以及执行 `Microsoft.Network/virtualNetworks/subnets/join/action` 的权限，包括网络位于其他资源组的情况。
- 选择认证方式：**SSH 公钥**（默认，推荐）或**用户名/密码**。密码认证无需生成密钥。使用公钥认证时，仅提供公钥，将私钥保留在客户端；为兼容 Azure Linux VM 预配，请使用 4096 位 RSA 密钥。
- 为公共 SSH 访问提供受信任的源公共 IP/CIDR，通常应填写你当前的公共 IP 地址。为便于快速访问，可以使用 `0.0.0.0/0` 允许任意源地址的 SSH 入站访问，但这仅适用于短期实验环境；请尽早将其替换为受信任的源 IP/CIDR。
- 首次启动期间，需要通过出站 DNS 和 HTTPS 访问 Ubuntu 软件源、Microsoft 软件包和安装端点、azd 扩展注册表，以及 GitHub/Kubernetes 下载端点。

## 一键式部署

[![部署到 Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Foxcp%2Fainotes%2Fmain%2Fagenthost%2Faz-toolbox-vm%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Foxcp%2Fainotes%2Fmain%2Fagenthost%2Faz-toolbox-vm%2FuiFormDefinition.json)

> [!tip]
> 按钮引用仓库 `main` 分支上的两份文件：
> - `main.json` 负责部署资源
> - 配套的 `uiFormDefinition.json` 负责界面
>
> 分享按钮前，请先确保Azure可以访问到仓库中的这两份文件。

## 架构

```text
资源组
  新建 VNet / 子网 / NSG，或使用已有 VNet / 子网
    NIC -- 可选的 Standard 静态公共 IPv4
      Ubuntu 24.04 VM / 系统分配的托管标识
        cloud-init -> 系统工具 + 管理员用户扩展 -> 验证
```

使用的镜像为 `Canonical:ubuntu-24_04-lts:server:latest`（x64，第 2 代）。模板只创建本研讨会的操作VM，不会创建 AKS 群集、Container Apps 环境等本Workshop中其它module的内容。

## 安装的工具

| 组件 | 安装方式 |
| --- | --- |
| Azure CLI | 安装时 Microsoft APT 仓库中可用的最新稳定版；验证已安装的软件包与当前 APT 候选版本一致，并满足研讨会最低版本 2.80.0（并非固定安装版本） |
| Git、curl、jq | Ubuntu 软件包 |
| Azure Developer CLI（`azd`） | Microsoft 当前稳定版本 |
| Microsoft Foundry 扩展 | `microsoft.foundry`，为配置的管理员用户安装 |
| kubectl | 通过 `az aks install-cli` 安装到 `/usr/local/bin`（同时安装配套的 kubelogin） |
| Container Apps 扩展 | 使用 `--upgrade --allow-preview true` 为管理员用户安装 |


## 部署说明

### 选择认证方式

模板支持以下两种方式：

| 方式 | 适用场景 |
| --- | --- |
| SSH 公钥（默认，推荐） | 优先考虑安全性，或计划长期使用 VM |
| 用户名/密码（可选） | 希望快速开始研讨会，不想生成或管理密钥，更便利 |

如使用SSH公钥，可以任选以下一种方式准备密钥：

**方式 A：在 Azure 门户生成密钥。** 在 **SSH 密钥（SSH keys）**服务中生成 RSA 密钥对，下载并妥善保存私钥，然后复制该资源的公钥，粘贴到模板相应的输入。

**方式 B：在 Windows PowerShell 中生成密钥。** Windows OpenSSH 客户端同时提供 `ssh` 和 `ssh-keygen`。在 PowerShell 中运行以下命令；私钥将保存在用户主目录：

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
ssh-keygen -t rsa -b 4096 -f "$env:USERPROFILE\.ssh\toolbox_rsa"
Get-Content "$env:USERPROFILE\.ssh\toolbox_rsa.pub"
```

按提示设置私钥口令，并将最后一条命令显示的完整公钥复制，粘贴到模板相应的输入。**不要上传私钥。**

**方式 C：在 Linux、WSL 或 Azure Cloud Shell 中生成密钥。** 在所选环境中运行：

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/toolbox_rsa
```

将生成的 `~/.ssh/toolbox_rsa.pub` 的完整内容填入模板相应的输入，并将私钥保留在用于连接 VM 的客户端；使用 Cloud Shell 时，请在会话结束前确保私钥已安全保存。


### 选择新建或已有网络

- **新建 VNet 和子网**（默认）：创建 VNet、子网和 NSG。需输入 VNet/子网名称和 CIDR。子网名默认是 `default`，可以自行修改。可以选择关联已有 NAT 网关。
- **使用已有 VNet 和已有子网**：选择器仅列出已有网络；模板只将 toolbox VM的NIC 加入选择的VNET/子网；模板不新创建 VNet、子网和 NSG，不修改已有子网的 NSG、路由、NAT 或默认出站访问配置，也不会向 NIC 添加 NSG。

已有 VNet 必须与 VM 位于同一订阅和区域。请选择兼容 VM NIC 且至少有一个可用地址的 IPv4 子网，不要使用保留的服务专用子网或不兼容的委派子网。你需要确保已有网络安全规则出站 DNS/HTTPS 可访问首次启动所需的下载端点。

### 仅专用网络与入站访问

选择不创建Public IP时，不会部署公共 IP 资源，也不会在 NIC 上关联公共 IP。通过SSH 连接到toolbox VM，需要依赖现有的专用路由，例如单独建立的对等互连/VPN 或 Bastion 连接。

新建网络时，NSG 可以设置入站规则，例如仅允许来自当前IP地址的，入站22端口 TCP 入站流量，包括原本默认允许的 VNet 范围内入站流量，并显式拒绝其他入站流量。默认出站 NSG 规则保持启用。使用已有网络，会保留原有安全与出站配置，需要单独确认。


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

安装程序会刷新基础软件包，将 Azure CLI 安装或升级到当时 Microsoft APT 仓库中可用的最新稳定版，验证其软件包版本与当前 APT 候选版本一致，安装当前稳定版 azd，安装或升级 Foundry，在允许预览版本的情况下升级 Container Apps，重新安装 kubectl，并重新验证。Azure CLI 不会固定安装为 2.80.0；该版本仅是安装程序和 `verify-tools.sh` 检查的研讨会兼容性下限。验证脚本不会检查新版本或升级工具。安装程序不会重复添加 profile 条目。不要并发运行多个安装程序。重试安装程序不会清除先前的 cloud-init 错误状态；请单独检查新日志和标记。除非打算重新执行所有首次启动处理，否则不要在已部署的 VM 上运行 `cloud-init clean`。

## 安全与生命周期

- 默认禁用 SSH 密码登录，仅在 `authenticationType=password` 时启用。密码通过 ARM `secureString` 参数传递，不会嵌入 cloud-init 或部署输出。不要提交私钥、密码、令牌或包含凭据的参数文件。
- 将公共 SSH 访问限制为受信任的 CIDR。对于长期使用的环境，优先采用仅专用网络 VM，并配合现有专用路由和显式 NAT 出站访问。
- 工具二进制文件安装在系统范围内。Azure CLI 和 azd 扩展配置在所选管理员用户的主目录中，而不仅是 `/root`；其他用户必须配置自己的扩展。
- 安装程序通过 HTTPS 下载 Microsoft 官方脚本，并以 root 身份执行。请根据环境要求审查上游安装程序和网络需求；工具版本有意跟随当前稳定版本，因此重新构建无法保证逐比特一致。
- 不会执行无人值守的完整操作系统升级。请根据运维策略维护操作系统安全补丁和工具更新。
- 更改源文件或重新部署不会在现有 VM 上重新运行 cloud-init。重新部署不是工具升级机制；请根据情况重试安装程序或重新创建 VM。
- VM 计算资源、磁盘和可选的公共 IP 会产生费用。
