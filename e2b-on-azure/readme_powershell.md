# Install E2B Embed on Azure: Step-by-Step Guide (PowerShell)

[Bash guide](readme.md) | **PowerShell guide**

> [!tip]
> To set up E2B when the Azure Storage account permits public access, follow the public-access [Bash](e2b_on_azure_blob_public_access_bash.md) or [PowerShell](e2b_on_azure_blob_public_access_powershell.md) guide instead.

Prepared October 19, 2026. Local commands use **PowerShell 7.4 or newer on Windows**. Scripts passed to Azure VM Run Command execute on the deployed **Ubuntu VM**, so those script strings intentionally use Linux commands.

This is the PowerShell companion to the [Bash guide](readme.md), using the same vendored module and private-storage topology. It deploys **E2B Embed on one Azure Linux VM**, managed by a single-instance VM Scale Set. Terraform creates the infrastructure, installs Docker, and starts the complete E2B stack automatically. You do not need AKS, an existing **E2B** VM, or an E2B Cloud account. You **do** need an existing Windows VM or self-hosted runner on the configured runner VNet to execute Terraform.

This walkthrough is based on the upstream [Azure README](https://github.com/e2b-dev/runtime/blob/main/embed/terraform/azure/README.md#install) and the locally adapted module. The module creates a dedicated `e2bvnet`, peers it with the runner VNet, and keeps Azure Storage public network access disabled through Blob Private Link.

> **Before starting:** this is a single-node deployment with plain HTTP and no persistent data disk. It is suitable for evaluating E2B, but needs additional networking, TLS, and operational design for sensitive production workloads.

## 1. Prepare the prerequisites

| Requirement | Details |
|---|---|
| Azure access | **Owner**, or **Contributor + User Access Administrator**, at the scope needed to create the resource group and role definitions/assignments |
| PowerShell | **7.4 or newer**, running on Windows; launch with `pwsh` |
| Terraform | **1.7.5 or newer** |
| Azure CLI | For authentication and troubleshooting |
| Git | For obtaining and tracking the vendored module |
| Python | For testing the E2B SDK; the examples use the `python` command |
| Azure capacity | A supported nested-virtualization VM size and sufficient regional/family vCPU quota |
| Private-network execution | An existing Windows Azure VM or self-hosted Windows runner attached to a VNet in the same subscription |
| Non-overlapping address space | A CIDR for `e2bvnet` that does not overlap the runner VNet or connected networks |

The deploying identity also needs permission to read the existing runner VNet and create a peering on it. By default, Terraform creates `privatelink.blob.core.windows.net` in the E2B resource group and links both VNets. Reusing a Private DNS Zone requires permission to create links and endpoint records in that zone. The runner VM and runner VNet remain outside this deployment's ownership.

Install missing tools using their official installers or Windows Package Manager:

```powershell
winget install --exact --id Microsoft.PowerShell
winget install --exact --id Microsoft.AzureCLI
winget install --exact --id Hashicorp.Terraform
winget install --exact --id Git.Git
winget install --exact --id Python.Python.3.12
```

Run installers only for tools that are missing. If `winget` is unavailable on your Windows Server runner, use the official [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows), [Terraform](https://developer.hashicorp.com/terraform/install), [Git](https://git-scm.com/downloads/win), and [Python](https://www.python.org/downloads/windows/) installers.

Open a new PowerShell 7 session after installation, then check:

```powershell
$PSVersionTable.PSVersion
az version
terraform version
git --version
python --version
curl.exe --version
```

`curl.exe` is the Windows curl executable, not the Windows PowerShell `curl` alias. If unavailable, install curl before the IPv4 check in step 5.

Keep the following settings in the session used for this walkthrough:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
```

PowerShell cmdlet failures and native executable failures will stop execution. Check each command's output before continuing; do not proceed after a failed Azure CLI operation. A backtick used for line continuation must be the **last character on its line**, with no trailing spaces.

**Docker is installed on the E2B Azure VM automatically. You do not need Docker Desktop on the runner.**

## 2. Sign in and select your Azure subscription

Run these commands on the private-network runner:

```powershell
az login
az account list --output table

$SubscriptionId = '<YOUR-SUBSCRIPTION-ID>'
az account set --subscription $SubscriptionId
$env:ARM_SUBSCRIPTION_ID = $SubscriptionId

az account show --output table
```

On a runner without an interactive browser, use `az login --use-device-code` if permitted by your organization's authentication policy.

`ARM_SUBSCRIPTION_ID` is required for the AzureRM 4.x provider. `$env:` variables are inherited by Terraform and Python launched from this session; they do not persist into a new PowerShell window. Repeat the setup if you reopen the shell.

Your identity must be able to create **custom roles and role assignments**, not just VMs.

## 3. Check the region and VM size

This guide uses the same target as the Bash walkthrough:

- Region: `southeastasia`
- Availability zone: `1`
- VM size: `Standard_D4ds_v7`
- RAM: 16 GiB
- OS: Ubuntu 24.04, x86-64
- OS disk: 50 GB Premium SSD

```powershell
az vm list-skus `
  --location southeastasia `
  --resource-type virtualMachines `
  --size Standard_D4ds_v7 `
  --all `
  --query "[?name=='Standard_D4ds_v7'].{name:name,zones:locationInfo[0].zones,restrictions:restrictions}" `
  --output json

az vm list-usage --location southeastasia --output table
```

Ensure zone `1` is available and no applicable subscription/zone restriction blocks the size. If unavailable, select another supported size, such as `Standard_D4ds_v5`, **after checking availability and quota**. The [module's validation](https://github.com/e2b-dev/runtime/blob/f9b828e76e190abe75d1cdd2d58fff6f4688ca34/embed/terraform/azure/variables.tf) accepts certain Intel D-series v3+, AMD D-series v5+, and L-series v3+ sizes.

**Do not substitute a B-series or ARM/Cobalt VM.** E2B sandboxes require nested virtualization and `/dev/kvm`.

## 4. Create a local Terraform working directory

Use a directory outside OneDrive or other automatically synchronized folders: **Terraform state contains secrets**. These commands are for a **new** deployment:

```powershell
$SourceDirectory = 'C:\path\to\ainotes\e2b-on-azure'
$DeploymentDirectory = Join-Path $HOME 'e2b-azure'

if (Test-Path -LiteralPath $DeploymentDirectory) {
    throw "Deployment directory already exists: $DeploymentDirectory. Use its existing state or choose a new empty directory."
}
New-Item -ItemType Directory -Path $DeploymentDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceDirectory 'main.tf') -Destination $DeploymentDirectory
Copy-Item -LiteralPath (Join-Path $SourceDirectory 'runtime') -Destination $DeploymentDirectory -Recurse
Set-Location -LiteralPath $DeploymentDirectory
```

Replace `$SourceDirectory` with your local checkout's `e2b-on-azure` directory. Confirm that `$DeploymentDirectory` is not synchronized before running the copy commands.

Copy the **complete** `runtime` tree, including its Compose files and `.env`. Do not copy only the Azure module directory. Do not copy `main_blob_public_access.tf`: Terraform loads every `*.tf` file, so it would duplicate providers, variables, the module, and outputs.

For a deployment that already failed partway through, use the **original deployment directory and state**, not a new directory. Back up and securely transfer the existing `terraform.tfstate` (for local state), `.terraform.lock.hcl`, variable files, and backend configuration to the runner. Do not transfer the machine-specific `.terraform` provider cache; run `terraform init` on the runner. Never commit state or upload it publicly.

The module call stays named `e2b`, preserving unchanged `module.e2b.*` resource addresses. The adapted VNet name and subnet layout differ from upstream; review the plan and state before applying to an existing deployment.

The checked-in [main.tf](main.tf) currently uses `eastus`. To match this walkthrough, edit the copied `main.tf` to use `southeastasia`, as shown below. The HCL syntax is the same in Bash and PowerShell; keep Terraform module paths in their existing form.

```hcl
terraform {
  required_version = ">= 1.7.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0, < 5.0"
    }
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

variable "client_cidrs" {
  description = "Public IPv4 CIDRs allowed to access E2B ports 3000, 3001, and 3002."
  type        = list(string)
}

variable "runner_vnet_name" {
  description = "Name of the existing VNet containing the VM that runs Terraform."
  type        = string
}

variable "runner_vnet_resource_group_name" {
  description = "Resource group of the existing VNet containing the VM that runs Terraform."
  type        = string
}

variable "e2b_vnet_address_space" {
  description = "Address space for e2bvnet. It must not overlap the runner VNet."
  type        = list(string)
  default     = ["10.10.0.0/24"]
}

variable "e2b_vm_subnet_prefixes" {
  description = "Address prefixes for the E2B VM subnet."
  type        = list(string)
  default     = ["10.10.0.0/25"]
}

variable "private_endpoint_subnet_prefixes" {
  description = "Address prefixes for the Storage private endpoint subnet."
  type        = list(string)
  default     = ["10.10.0.128/26"]
}

variable "blob_private_dns_zone_id" {
  description = "Optional existing privatelink.blob.core.windows.net zone ID. Leave null to create one."
  type        = string
  default     = null
  nullable    = true
}

variable "link_runner_vnet_to_blob_private_dns_zone" {
  description = "Create the Blob Private DNS Zone link to the runner VNet."
  type        = bool
  default     = true
}

module "e2b" {
  source = "./runtime/embed/terraform/azure"

  name                                    = "e2b-embed-demo"
  location                                = "southeastasia"
  zone                                    = "1"
  instance_size                           = "Standard_D4ds_v7"
  client_cidrs                            = var.client_cidrs
  vnet_name                               = "e2bvnet"
  vnet_address_space                      = var.e2b_vnet_address_space
  vm_subnet_name                          = "e2b-vm"
  vm_subnet_prefixes                      = var.e2b_vm_subnet_prefixes
  private_endpoint_subnet_name            = "private-endpoints"
  private_endpoint_subnet_prefixes        = var.private_endpoint_subnet_prefixes
  runner_vnet_name                        = var.runner_vnet_name
  runner_vnet_resource_group_name         = var.runner_vnet_resource_group_name
  blob_private_dns_zone_id                = var.blob_private_dns_zone_id
  link_runner_vnet_to_blob_private_dns_zone = var.link_runner_vnet_to_blob_private_dns_zone
}

output "api_url" {
  value = module.e2b.api_url
}

output "sandbox_url" {
  value = module.e2b.sandbox_url
}

output "dashboard_url" {
  value = module.e2b.dashboard_url
}

output "run_command" {
  value = module.e2b.run_command
}

output "e2b_api_key" {
  value     = module.e2b.e2b_api_key
  sensitive = true
}

output "admin_password" {
  value     = module.e2b.admin_password
  sensitive = true
}

output "storage_account_name" {
  value = module.e2b.storage_account_name
}

output "blob_private_endpoint_ip" {
  value = module.e2b.blob_private_endpoint_ip
}

output "e2b_vnet_id" {
  value = module.e2b.vnet_id
}

output "e2b_vm_subnet_id" {
  value = module.e2b.vm_subnet_id
}
```

Important details:

- The vendored module is based on upstream commit `f9b828e76e190abe75d1cdd2d58fff6f4688ca34`, checked on October 15, 2026. Reapply the local network and Private Link changes when upgrading it.
- `storage_use_azuread = true` is required because shared-key authentication is disabled.
- Use a different `name` for another installation in the same tenant; custom role names must be unique.
- The outputs expose the module's values to `terraform output`.

## 5. Configure the runner VNet, E2B network, and client CIDRs

On each workstation or application host that will access E2B, find its outbound public IPv4 address:

```powershell
curl.exe -4 --fail --silent --show-error https://api.ipify.org
Write-Host
```

If your browser or SDK runs on a different machine from the runner, allow that machine's outbound IP as well, not just the runner's IP.

Back in the deployment directory on the runner, create `terraform.tfvars` after replacing the placeholders:

```powershell
@'
runner_vnet_name                = "YOUR-RUNNER-VNET-NAME"
runner_vnet_resource_group_name = "YOUR-RUNNER-VNET-RESOURCE-GROUP"

client_cidrs = ["YOUR-PUBLIC-IPV4/32"]
'@ | Set-Content -LiteralPath .\terraform.tfvars -Encoding utf8NoBOM
```

This writes a new variable file; **edit rather than overwrite** an existing deployment's file. Single-quoted here-strings preserve literal HCL, and `utf8NoBOM` writes UTF-8 without a byte-order mark. The closing `'@` must start at the beginning of its line.

An IPv4 CIDR looks like `198.51.100.7/32`, but **that example is not your IP**. To allow multiple clients, use:

```hcl
client_cidrs = [
  "YOUR-WORKSTATION-PUBLIC-IPV4/32",
  "YOUR-APPLICATION-OUTBOUND-IPV4/32"
]
```

| Port | Service |
|---|---|
| 3000 | E2B API |
| 3001 | Dashboard |
| 3002 | Sandbox traffic proxy |

**Do not use `0.0.0.0/0`.** VPNs, proxies, and changing home IPs may require updates. Port 22 is intentionally closed.

The default network layout is:

```hcl
e2b_vnet_address_space           = ["10.10.0.0/24"]
e2b_vm_subnet_prefixes           = ["10.10.0.0/25"]
private_endpoint_subnet_prefixes = ["10.10.0.128/26"]
```

Change all three values together if the VNet CIDR overlaps the runner VNet, peered networks, VPN/ExpressRoute routes, or on-premises networks. Azure rejects peering between overlapping address spaces.

By default, Terraform creates the Blob Private DNS Zone and links both VNets. To reuse an existing zone, add to `terraform.tfvars`:

```hcl
blob_private_dns_zone_id = "/subscriptions/<SUBSCRIPTION-ID>/resourceGroups/<DNS-RESOURCE-GROUP>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
```

If the runner VNet is already linked to that exact zone and the link is managed elsewhere, also set:

```hcl
link_runner_vnet_to_blob_private_dns_zone = false
```

### Storage Private Link and the bootstrap sequence

`client_cidrs` controls E2B services, **not Storage access**.

```text
Existing Windows Terraform runner VM in its VNet
    |
    | Bidirectional global VNet peering
    v
E2B VNet (southeastasia, 10.10.0.0/24)
    |-- e2b-vm (10.10.0.0/25) --> Ubuntu E2B VMSS
    |
    `-- private-endpoints (10.10.0.128/26)
          |
          v
        Blob Private Endpoint --> Storage Account (public access disabled)

privatelink.blob.core.windows.net
    | Link: runner VNet
    ` Link: E2B VNet
```

The runner does not need the Storage Account to exist first. It needs Azure credentials, access to management/authentication endpoints, and attachment to the configured VNet. Terraform creates the E2B VNet, subnets, peerings, Storage Account, Private Endpoint, DNS zone group, and DNS links through the management API.

The two Blob uploads wait for these resources, a 60-second private-network propagation delay, and RBAC propagation. Only after uploading the files does Terraform start the E2B VMSS in the VM subnet. This avoids relying on an E2B VM that cannot boot until its Compose files exist, without opening Storage publicly.

The 60-second delay is not proof of connectivity. NSGs, routes, DNS caches, and custom DNS must permit the runner to resolve and reach the endpoint on TCP 443. With custom DNS, configure conditional forwarding for `privatelink.blob.core.windows.net` through Azure DNS Private Resolver or an equivalent path. Keep using `<account>.blob.core.windows.net`, not a `privatelink` URL or an IP address.

## 6. Deploy with Terraform

Run in the deployment directory **on the Windows VM in the configured runner VNet**, authenticated as in step 2 with `$env:ARM_SUBSCRIPTION_ID` set. An ordinary machine outside the private DNS/network path cannot perform the Blob data-plane operations.

```powershell
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Review the plan and enter `yes` to approve creation. For an earlier deployment, migrate/import state where appropriate rather than accepting unexpected replacement of an in-use VNet, VMSS, or Storage Account.

Terraform provisions the dedicated VNet, both subnets, bidirectional peering, VMSS, **two public IPs**, NAT gateway, identity, Storage Account, RBAC resources, Blob Private Endpoint, and DNS links. It creates the DNS Zone unless you supply an existing one. The Ubuntu VM then installs Docker and starts E2B.

| Milestone | Approximate upstream timing |
|---|---|
| Terraform apply completes | 7 minutes after starting apply |
| API `/health` responds | 2 minutes after apply completes |
| First sandbox can start | 7 minutes after apply completes |

These are upstream measurements, not guarantees. The local Private Link configuration adds a 60-second propagation wait and may take longer. Allow roughly **15-20 minutes** or more for deployment and verification.

Charges apply for the VM, Premium disk, NAT gateway, public IPs, storage, Private Endpoint, and applicable traffic, including global VNet peering.

Verify private DNS and authenticated Blob access from the runner:

```powershell
$StorageAccount = terraform output -raw storage_account_name
$ExpectedPrivateIp = terraform output -raw blob_private_endpoint_ip
$BlobHostName = "$StorageAccount.blob.core.windows.net"

Resolve-DnsName -Name $BlobHostName -Type A
Write-Host "Expected private endpoint IP: $ExpectedPrivateIp"
Test-NetConnection -ComputerName $BlobHostName -Port 443

az storage blob list `
  --account-name $StorageAccount `
  --container-name compose `
  --auth-mode login `
  --query "[].name" `
  --output json
```

The service hostname must resolve to the expected private IP, the TCP test must succeed, and the Blob list should contain `compose.yaml` and `.env`.

## 7. Configure your local SDK and verify the API

From the deployment directory:

```powershell
$env:E2B_API_URL = terraform output -raw api_url
$env:E2B_SANDBOX_URL = terraform output -raw sandbox_url
$env:E2B_API_KEY = terraform output -raw e2b_api_key

Invoke-RestMethod -Uri "$env:E2B_API_URL/health" -Method Get
```

If startup is still in progress, wait and retry. A successful health check **does not mean the initial `base` template build has finished**.

Open the dashboard:

```powershell
$DashboardUrl = terraform output -raw dashboard_url
Write-Host "Open the dashboard in your browser: $DashboardUrl"
Start-Process -FilePath $DashboardUrl
```

If the runner has no browser, open the URL on an allowed workstation. Retrieve the key locally and paste it into the dashboard key form:

```powershell
terraform output -raw e2b_api_key
```

Treat it as a secret; do not put it in shared logs, transcripts, screenshots, or source control. If running the SDK elsewhere, set the same three environment variables securely in that machine's PowerShell session without copying Terraform state there, and ensure its outbound IP is allowed.

## 8. Create your first sandbox

Install the SDK version used by the Bash guide:

```powershell
python -m venv .venv
& .\.venv\Scripts\python.exe -m pip install e2b==2.46.0
```

Calling the virtual environment's interpreter directly avoids changing the execution policy or activating the environment.

Create `test_e2b.py`:

```powershell
@'
from e2b import Sandbox

sandbox = Sandbox.create("base")
try:
    result = sandbox.commands.run("echo hello from the sandbox")
    print(result.stdout)
finally:
    sandbox.kill()
'@ | Set-Content -LiteralPath .\test_e2b.py -Encoding utf8NoBOM
```

Run in the same session where the E2B environment variables were set:

```powershell
& .\.venv\Scripts\python.exe .\test_e2b.py
```

Expected output:

```text
hello from the sandbox
```

If you receive:

```text
404: tag 'default' does not exist for template 'local-dev-team/base'
```

the initial template build may still be running. Wait a minute and retry. A template appearing in the API's template list is **not sufficient proof that its build is ready**.

## 9. Run the packaged smoke test and troubleshoot

Look up the current VMSS instance:

```powershell
$ResourceGroup = 'e2b-embed-demo'
$VmName = az vm list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --query "[0].name" `
  --output tsv
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to query the deployed VM.'
}
if ([string]::IsNullOrWhiteSpace($VmName)) {
    throw "No VM found in resource group $ResourceGroup. Check deployment status."
}
```

If you changed the module's `name`, adjust `$ResourceGroup`. Use the subscription selected in step 2.

Check KVM and run the smoke test:

```powershell
az vm run-command invoke `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --name $VmName `
  --command-id RunShellScript `
  --scripts 'set -e; ls -l /dev/kvm; cd /opt/e2b; docker compose --profile test run --rm smoke'
```

The packaged test checks sandbox creation and access to a port inside the sandbox. Inspect Run Command's returned stdout/stderr and script exit status; successful submission alone does not prove the smoke test passed.

For startup diagnostics:

```powershell
az vm run-command invoke `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --name $VmName `
  --command-id RunShellScript `
  --scripts 'tail -n 100 /var/log/cloud-init-output.log; journalctl -u e2b-embed -n 100'
```

The `--scripts` values intentionally remain Linux shell code: Azure executes them **on Ubuntu**, not in local PowerShell. Single quotes keep PowerShell from expanding shell variables in those strings. Review logs for secrets before sharing.

| Symptom | What to check |
|---|---|
| Role creation/assignment denied | Owner, or Contributor + User Access Administrator permissions |
| `AuthorizationPermissionMismatch` during Blob upload | RBAC propagation; retry `terraform apply` after propagation |
| Blob 403 or timeout with public access disabled | Use the private runner; verify private DNS, both peerings, endpoint approval, routes, and TCP 443. Do not enable public access to bypass organizational policy |
| VM SKU or zone deployment failure | Subscription restrictions, zone availability, and vCPU quota |
| API/dashboard connection timeout | Startup progress and the actual client public IP in `client_cidrs` |
| API healthy, initial sandbox creation fails | The `base` template build may still be running |
| `/dev/kvm` missing | VM size lacks the required nested virtualization |
| PowerShell continuation or encoding errors | Use PowerShell 7.4+, no spaces after continuation backticks, and UTF-8 files as shown above |

## 10. Understand persistence and clean up

**Before relying on this deployment:**

- Traffic uses **plain HTTP**; CIDR restrictions do not encrypt API keys or sandbox traffic.
- Secrets exist in Terraform state and VM custom data. The upstream README warns that Azure Reader access can expose custom data.
- The module's Storage Account is **not a Terraform remote-state backend**. Configure a protected backend separately for shared or production operation.
- Automatic repair replaces an unhealthy VM with a fresh disk. Templates and local data are lost.
- Running `docker compose down` is not a safe pause: the health mechanism can replace the instance.

When finished, run from the original deployment directory:

```powershell
terraform plan -destroy
terraform destroy
```

Destroy from the private runner while its network and DNS path remain intact. Review and confirm destruction. This removes the E2B resource group, VNet, subnets, Private Endpoint, both peering directions, and DNS links created by this deployment. **VM-local templates and data will be lost.**

The existing runner VM and VNet remain. A supplied existing Private DNS Zone and any runner DNS link excluded with `link_runner_vnet_to_blob_private_dns_zone = false` remain outside this deployment's state.

Clear the SDK credentials from this PowerShell session when no longer needed:

```powershell
Remove-Item Env:\E2B_API_KEY, Env:\E2B_API_URL, Env:\E2B_SANDBOX_URL
```
