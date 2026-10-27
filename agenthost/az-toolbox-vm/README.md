# Setup Linux toolbox VM

> 🌐 语言 / Language: **English** | [中文](README_CN.md)

Deploy an Ubuntu 24.04 LTS engineering workstation with the tools required for this workshop preinstalled, using Bicep or Azure Portal Custom Deployment.

## Prerequisites

- An Azure subscription and permission to deploy compute and network resources to the target resource group, including permission to create a system-assigned identity.
- Sufficient regional quota and capacity for the selected x64 Generation 2 VM size. The default is `Standard_D4s_v5`.
- When using an existing subnet, permission to read its VNet and subnet and to perform `Microsoft.Network/virtualNetworks/subnets/join/action`, including when the network is in another resource group.
- Choose an authentication method: **SSH public key** (the default and recommended option) or **username/password**. Password authentication does not require key generation. For key-based authentication, provide only the public key and keep the private key on your client. Use a 4096-bit RSA key for compatibility with Azure Linux VM provisioning.
- A trusted source public IP address or CIDR range for public SSH access, typically your current public IP address(es). For quick access, you can use `0.0.0.0/0` to allow inbound SSH traffic from any source, but this is intended only for short-lived labs; replace it with a trusted source IP/CIDR as soon as possible.
- Outbound DNS and HTTPS access during first boot to Ubuntu repositories, Microsoft package and installation endpoints, the azd extension registry, and GitHub and Kubernetes download endpoints.

## One-click deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Foxcp%2Fainotes%2Fmain%2Fagenthost%2Faz-toolbox-vm%2Fmain.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Foxcp%2Fainotes%2Fmain%2Fagenthost%2Faz-toolbox-vm%2FuiFormDefinition.json)

> [!TIP]
> The button references two files on the repository's `main` branch:
> - `main.json` deploys the resources.
> - The companion `uiFormDefinition.json` controls the interface.
>
> Before sharing the button, ensure Azure can access both files in the repository.

## Architecture

```text
Resource group
  New VNet / subnet / NSG, or existing VNet / subnet
    NIC -- optional Standard static public IPv4
      Ubuntu 24.04 VM / system-assigned managed identity
        cloud-init -> system tools + admin-user extensions -> verification
```

The image is `Canonical:ubuntu-24_04-lts:server:latest` (x64, generation 2). The template creates only the administration VM for this workshop; it does not create AKS clusters, Container Apps environments, or resources covered by the other workshop modules.

## Installed tools

| Component | Installation |
| --- | --- |
| Azure CLI | Latest stable release available from Microsoft's APT repository at installation time; verifies the installed package matches the current APT candidate and meets the workshop minimum of 2.80.0 (not a pinned version) |
| Git, curl, jq | Ubuntu packages |
| Azure Developer CLI (`azd`) | Current stable Microsoft release |
| Microsoft Foundry extension | `microsoft.foundry`, installed for the configured admin user |
| kubectl | `az aks install-cli`, installed in `/usr/local/bin` (also installs its kubelogin companion) |
| Container Apps extension | Installed for the admin user with `--upgrade --allow-preview true` |

## Deployment guidance

### Choosing an authentication method

The template supports the following two methods:

| Method | When to choose it |
| --- | --- |
| SSH public key (default, recommended) | You prioritize security or plan to use the VM long term |
| Username/password (optional) | You want a more convenient, quick start to the workshop without generating or managing keys |

If you use an SSH public key, choose any one of these ways to prepare a key:

**Option A: Generate a key in Azure Portal.** Use the **SSH keys** service to generate an RSA key pair, download and securely store the private key, then copy the resource's public key into the corresponding template input.

**Option B: Generate a key in Windows PowerShell.** Windows OpenSSH Client includes both `ssh` and `ssh-keygen`. Run the following in PowerShell; the private key is stored in your user profile:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
ssh-keygen -t rsa -b 4096 -f "$env:USERPROFILE\.ssh\toolbox_rsa"
Get-Content "$env:USERPROFILE\.ssh\toolbox_rsa.pub"
```

Set a private-key passphrase when prompted, then copy the complete public key displayed by the last command into the corresponding template input. **Do not upload the private key.**

**Option C: Generate a key in Linux, WSL, or Azure Cloud Shell.** Run the following in your chosen environment:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/toolbox_rsa
```

Supply the complete contents of the generated `~/.ssh/toolbox_rsa.pub` in the corresponding template input, and keep the private key on the client you will use to connect. When using Cloud Shell, ensure the private key is securely saved before ending the session.

### Choosing a new or existing network

- **New VNet and subnet** (default): creates the VNet, subnet, and NSG. Enter the VNet/subnet names and CIDRs. The subnet name defaults to `default` and is editable. An existing NAT gateway can optionally be attached.
- **Existing VNet and existing subnet**: the selector lists only existing networks. The template only joins the toolbox VM's NIC to the selected VNet/subnet; it creates no new VNet, subnet, or NSG and does not change the existing subnet's NSG, routes, NAT, or default outbound access. It also adds no NSG to the NIC.

The existing VNet must be in the same subscription and region as the VM. Choose an IPv4 subnet compatible with VM NICs, with at least one free address; do not use a reserved service subnet or an incompatible delegated subnet. Ensure the existing network security rules allow outbound DNS/HTTPS access to the download endpoints required during first boot.

### Private-only networking and inbound access

If you choose not to create a public IP, no public IP resource or NIC public-IP association is deployed. Connecting to the toolbox VM over SSH requires existing private routing, such as peering/VPN or Bastion connectivity established separately.

For new networks, the template adds an inbound rule allowing TCP port 22 from the configured SSH source IP/CIDR. Other Azure default NSG inbound rules remain unchanged: for example, inbound traffic from the `VirtualNetwork` and `AzureLoadBalancer` service tags is allowed, while inbound traffic that does not match an allow rule is still denied by the default `DenyAllInBound` rule. Default outbound NSG rules remain enabled.

When using an existing network, its current NSG inbound and outbound rules are preserved. Check separately whether these rules affect tool installation on the toolbox VM.

## Validation

SSH using the deployment output address and configured username (replace `azureuser` if you changed it). Windows users can run these commands in PowerShell with the Windows OpenSSH Client; WSL is not required. If `ssh` is unavailable, install **OpenSSH Client** from Windows Optional Features.

For password authentication, run the following and enter the password at the prompt (do not put it in the command):

```bash
ssh azureuser@VM_IP_ADDRESS
```

For SSH key authentication, use your downloaded or locally generated private key:

```bash
ssh -i ~/.ssh/toolbox_rsa azureuser@VM_IP_ADDRESS
```

In Windows PowerShell, use this path syntax (replace it with the actual download path if you downloaded the private key from the portal):

```powershell
ssh -i "$env:USERPROFILE\.ssh\toolbox_rsa" azureuser@VM_IP_ADDRESS
```

On the first connection, verify the target VM's host key fingerprint before accepting the prompt. If you set a private-key passphrase, key authentication prompts for that passphrase, not the VM user's password. After connecting, run the following Linux commands on the remote VM, not in your local PowerShell session.

On the VM, wait for initialization, then verify as **azureuser** (or your configured admin user), without sudo:

```bash
cloud-init status --wait
/usr/local/bin/verify-tools.sh
test -f /var/lib/toolbox-install-complete && echo "READY" || echo "NOT READY"
```

## Troubleshooting

> [!TIP]
> This section is only a troubleshooting reference for problems installing the toolbox VM. If the toolbox VM was installed successfully, skip this section.

Run on the VM:

```bash
cloud-init status --long
sudo less /var/log/cloud-init-output.log
sudo less /var/log/toolbox-install.log
sudo cat /var/log/toolbox-versions.log
test -f /var/lib/toolbox-install-complete && echo "READY" || echo "NOT READY"
```

`/var/log/cloud-init-output.log` includes package-stage failures that can happen before the toolbox installer starts. `/var/log/toolbox-install.log` records installation progress and errors. A missing report/marker means validation has not completed successfully. Use managed boot diagnostics from the VM's Portal page if SSH is unavailable.

If SSH fails, check the username, the password or matching private key for the selected authentication method, public/private address, NSG source CIDR, and private routing. If installation fails, check DNS/HTTPS egress, Azure Policy, upstream package/extension availability, and the first error in the logs.

After correcting an installation problem, rerun **only after cloud-init has finished**:

```bash
sudo bash /usr/local/sbin/install-toolbox.sh
/usr/local/bin/verify-tools.sh
```

The installer refreshes base packages, installs or upgrades Azure CLI to the latest stable release available from Microsoft's APT repository at that time, verifies that its package version matches the current APT candidate, installs the current stable azd, installs or upgrades Foundry, upgrades Container Apps with preview releases allowed, reinstalls kubectl, and revalidates. Azure CLI is not pinned to 2.80.0; that version is only the workshop compatibility minimum checked by the installer and `verify-tools.sh`. The verification script does not check for new releases or upgrade tools. The installer does not duplicate profile entries. Do not run concurrent installers. Retrying the installer does not clear an earlier cloud-init error status; inspect the new logs and marker independently. Avoid `cloud-init clean` on a deployed VM unless you intend to repeat all first-boot processing.

## Security and lifecycle

- SSH password login is disabled by default and enabled only when `authenticationType=password`. The password is passed as an ARM `secureString` parameter, never embedded in cloud-init or deployment outputs. Do not commit private keys, passwords, tokens, or parameter files containing credentials.
- Restrict public SSH to a trusted CIDR. A private-only VM plus existing private routing and explicit NAT egress is preferred for longer-lived environments.
- Tool binaries are installed system-wide. Azure CLI and azd extensions are configured in the chosen admin user's home, not just `/root`; additional users must configure their own extensions.
- Installers download official Microsoft scripts over HTTPS and execute them as root. Review upstream installers and network requirements for your environment; tool versions intentionally follow current stable releases, so rebuilds are not bit-for-bit reproducible.
- No unattended full OS upgrade is performed. Maintain OS security patches and tool updates according to your operational policy.
- Changing source files or redeploying does not rerun cloud-init on an existing VM. Redeploying is not a tool-upgrade mechanism; retry the installer or recreate the VM as appropriate.
- VM compute, disk, and optional public IP incur charges.
