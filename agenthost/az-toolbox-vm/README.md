# Azure Linux toolbox VM

Deploy an Ubuntu 24.04 LTS engineering workstation using Bicep or Azure Portal Custom Deployment. `main.bicep` is the infrastructure source of truth; `main.json` is generated and includes cloud-init and the verification script. Portal deployment needs only `main.json`, not separately hosted scripts.

## Architecture

```text
Resource group
  VNet / subnet / NSG
    NIC -- optional Standard static public IPv4
      Ubuntu 24.04 VM / system-assigned managed identity
        cloud-init -> system tools + admin-user extensions -> verification
```

The image is `Canonical:ubuntu-24_04-lts:server:latest` (x64, generation 2). The template creates no AKS cluster, Container Apps environment, registry, storage account, Key Vault, or Foundry project, and assigns no RBAC roles. Boot diagnostics uses platform-managed storage.

Installed tools:

| Component | Installation |
| --- | --- |
| Azure CLI | Current stable Microsoft release, checked against minimum 2.80.0 |
| Git, curl, jq | Ubuntu packages |
| Azure Developer CLI (`azd`) | Current stable Microsoft release |
| Microsoft Foundry extension | `microsoft.foundry`, installed for the configured admin user |
| kubectl | `az aks install-cli`, installed in `/usr/local/bin` (also installs its kubelogin companion) |
| Container Apps extension | Installed for the admin user with `--upgrade --allow-preview true` |

[AKS Pod Sandboxing](https://learn.microsoft.com/azure/aks/use-pod-sandboxing) currently requires Azure CLI 2.80.0+ and kubectl, not `aks-preview` or a separate sandboxing extension. Verification checks that `az aks create` exposes `--workload-runtime`. The Ubuntu VM is an administration client; sandboxed AKS node pools themselves require Azure Linux. The Foundry extension and some Container Apps commands may be preview even though the infrastructure APIs and CLI installers are stable. Allowing Container Apps preview releases does not force a preview version when the current release is stable.

## Prerequisites

- An Azure subscription and permission to deploy compute/network resources into the target resource group, including a system-assigned identity.
- Regional quota and capacity for the selected x64 generation 2 VM size; the default is `Standard_D4s_v5`.
- An SSH key pair. Supply only its public key; keep the private key on your client. Azure Linux VM public-key provisioning supports RSA SSH keys; use a 4096-bit RSA key for compatibility.
- A trusted source public IP/CIDR for public SSH. The default `*` is intended only for short-lived labs; replace it before deployment.
- For CLI deployment or regeneration: Azure CLI, Bicep CLI, and these source files. Sign in with `az login` and select your subscription separately.
- Outbound DNS and HTTPS access to Ubuntu repositories, Microsoft package/install endpoints, the azd extension registry, and GitHub/Kubernetes download endpoints during first boot.

Create a key if needed (on your client, not in the repository):

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/toolbox_rsa
```

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `location` | Resource group location | Resource region |
| `vmName` | `azure-toolbox-vm` | VM and derived resource names |
| `adminUsername` | `azureuser` | SSH user and owner of user-scoped extensions |
| `vmSize` | `Standard_D4s_v5` | x64 generation 2 compatible VM size |
| `sshPublicKey` | Required | Full public key text |
| `createPublicIp` | `true` | Attach a public IPv4 address |
| `sshAllowedSource` | `*` with public IP; otherwise `VirtualNetwork` | SSH source IP/CIDR or service tag |
| `vnetName` | `vnet-toolbox` | New VNet name |
| `vnetAddressPrefix` | `10.10.0.0/16` | VNet address space |
| `subnetName` | `default` | New subnet name |
| `subnetAddressPrefix` | `10.10.0.0/24` | Subnet range within the VNet |
| `existingNatGatewayResourceId` | Empty | Optional existing NAT gateway for explicit egress |

Use valid Azure resource names and a valid Linux admin username/hostname. Choose nonoverlapping network ranges. This template owns the VNet and subnet: use unique names rather than pointing it at a shared VNet. For multiple deployments in one resource group, choose unique `vmName` and `vnetName` values.

### Private-only networking and outbound access

With `createPublicIp=false`, no public IP resource or NIC public-IP association is deployed, and the public-IP output is an empty string. SSH requires an existing private route, such as peering/VPN or Bastion connectivity established separately. Setting an SSH source does not create that route.

For a minimal private-only lab without a NAT gateway, the subnet explicitly opts into Azure default outbound access (`defaultOutboundAccess=true`) so first-boot downloads can work without creating extra infrastructure. This is implicit, nondeterministic egress, not an attached public IP or inbound path. It is not the recommended production configuration; Azure now defaults new subnets to private in newer APIs. See [default outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access).

For predictable production egress, supply `existingNatGatewayResourceId` for a compatible NAT gateway in the same region with a configured public IP/prefix and available subnet capacity. The template attaches it but does not create or manage it. The subnet disables default outbound access whenever NAT is supplied or the VM has its own public IP. Ensure policies permit the selected configuration before deploying; a private-only deployment that disallows default outbound access needs the existing NAT gateway.

The NSG permits TCP/22 only from `sshAllowedSource` and explicitly denies other inbound traffic, including the otherwise default VNet-wide inbound allowance. Default outbound NSG rules remain enabled for installation.

## Azure Portal deployment

![Toolbox VM deployment in Azure Portal](../pic/toolbox-vm-deployment.png)

1. Open Azure Portal and search for **Deploy a custom template**.
2. Select **Build your own template in the editor**.
3. Select **Load file** and load this directory's generated `main.json`.
4. Select **Save**.
5. Choose your subscription and resource group, then review the deployment parameters.
6. Paste the complete SSH **public** key into `sshPublicKey`; set `sshAllowedSource` to your trusted public IP/CIDR. Change the admin username or other parameters as needed.
7. Select **Review + create**, then **Create** after validation succeeds.
8. Use the deployment outputs for the VM name, resource ID, private/public address, and admin username.

Azure deployment success means the VM was provisioned, **not** that cloud-init has finished installing the tools. Wait and verify as described below.

## Azure CLI deployment

The following examples use Bash (including Azure Cloud Shell). Replace the resource group and source CIDR with your own values; no subscription or resource group is embedded in the template.

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

For a private-only VM with explicit outbound NAT:

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

`NAT_GATEWAY_RESOURCE_ID` must identify your existing, configured NAT gateway. Omit that parameter only for the lab default-egress behavior described above. Configure private routing separately before expecting SSH connectivity.

View outputs:

```bash
az deployment group show \
  --name toolbox \
  --resource-group "${RESOURCE_GROUP}" \
  --query properties.outputs --output json
```

## Regenerate the Portal template

After changing Bicep, cloud-init, or `scripts/verify-tools.sh`, run:

```bash
az bicep build \
  --file main.bicep \
  --outfile main.json
```

Commit the regenerated `main.json` with its sources. Do not edit its infrastructure logic by hand. Bicep embeds cloud-init and a base64 copy of the single verification-script source. It also base64-encodes the configured username into a data file, rather than interpolating it into shell commands.

## Validation

SSH using the deployment output address and configured username:

```bash
ssh -i ~/.ssh/toolbox_rsa azureuser@VM_IP_ADDRESS
```

On the VM, wait for initialization, then verify as the **normal admin user**, without sudo:

```bash
cloud-init status --wait
/usr/local/bin/verify-tools.sh
test -f /var/lib/toolbox-install-complete && echo "READY" || echo "NOT READY"
```

If you copied the repository onto the VM, you can also run `bash scripts/verify-tools.sh`. Verification displays tool versions, checks the Azure CLI minimum, checks the AKS sandboxing CLI option, and requires both extensions to be installed for the current user. It needs no Azure login or running cluster. Listing azd extensions can still require access to the extension registry.

Inspect the automatic version report:

```bash
sudo cat /var/log/toolbox-versions.log
```

The completion marker is created only after mandatory installation and validation succeed. The installer removes an old marker/report before retrying. No success marker is created on failure, although a failed validation can leave a partial version report.

You can also inspect infrastructure configuration from your client:

```bash
az vm show --resource-group "${RESOURCE_GROUP}" --name azure-toolbox-vm \
  --query '{image:storageProfile.imageReference,passwordDisabled:osProfile.linuxConfiguration.disablePasswordAuthentication,identity:identity.type}' \
  --output json
```

SSH login, cloud-init readiness, and actual tool installation must be checked on a deployed VM; compiling the template alone does not prove these runtime outcomes.

## Troubleshooting

Run on the VM:

```bash
cloud-init status --long
sudo less /var/log/cloud-init-output.log
sudo less /var/log/toolbox-install.log
sudo cat /var/log/toolbox-versions.log
test -f /var/lib/toolbox-install-complete && echo "READY" || echo "NOT READY"
```

`/var/log/cloud-init-output.log` includes package-stage failures that can happen before the toolbox installer starts. `/var/log/toolbox-install.log` records installation progress and errors. A missing report/marker means validation has not completed successfully. Use managed boot diagnostics from the VM's Portal page if SSH is unavailable.

If SSH fails, check the username, matching private key, public/private address, NSG source CIDR, and private routing. If installation fails, check DNS/HTTPS egress, Azure Policy, upstream package/extension availability, and the first error in the logs.

After correcting an installation problem, rerun **only after cloud-init has finished**:

```bash
sudo bash /usr/local/sbin/install-toolbox.sh
/usr/local/bin/verify-tools.sh
```

The installer refreshes base packages, installs current stable CLIs, installs or upgrades Foundry, upgrades Container Apps with preview releases allowed, reinstalls kubectl, and revalidates. It does not duplicate profile entries. Do not run concurrent installers. Retrying the installer does not clear an earlier cloud-init error status; inspect the new logs and marker independently. Avoid `cloud-init clean` on a deployed VM unless you intend to repeat all first-boot processing.

## Security and lifecycle

- SSH passwords are disabled; do not commit private keys, passwords, tokens, or other credentials.
- Restrict public SSH to a trusted CIDR. A private-only VM plus existing private routing and explicit NAT egress is preferred for longer-lived environments.
- Tool binaries are installed system-wide. Azure CLI and azd extensions are configured in the chosen admin user's home, not just `/root`; additional users must configure their own extensions.
- The system-assigned managed identity has no RBAC assignments. An authorized operator must separately grant the minimum required role at the smallest scope before `az login --identity` can access Azure resources.
- Installers download official Microsoft scripts over HTTPS and execute them as root. Review upstream installers and network requirements for your environment; tool versions intentionally follow current stable releases, so rebuilds are not bit-for-bit reproducible.
- No unattended full OS upgrade is performed. Maintain OS security patches and tool updates according to your operational policy.
- Changing source files or redeploying does not rerun cloud-init on an existing VM. Redeploying is not a tool-upgrade mechanism; retry the installer or recreate the VM as appropriate. Azure also restricts changes to existing VM custom data.
- VM compute, disk, and optional public IP incur charges. Delete only this deployment's owned resources when no longer needed; do not delete a shared resource group or the separately managed NAT gateway.
