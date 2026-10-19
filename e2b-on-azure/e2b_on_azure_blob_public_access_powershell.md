# Install E2B Embed on Azure: Step-by-Step Guide (Powershell)

> [!tip]
> To set up when the Azure Storage account prohibits public access, follow the [PowerShell Private Link guide](readme_powershell.md).

Prepared October 14, 2026. Commands use Windows PowerShell unless otherwise indicated.

The linked module deploys **E2B Embed on one Azure Linux VM**, managed by a single-instance VM Scale Set. Terraform creates the infrastructure, installs Docker, and starts the complete E2B stack automatically. **You do not need AKS, an existing VM, or an E2B Cloud account.**

This walkthrough is based on the [Azure README](https://github.com/e2b-dev/runtime/blob/main/embed/terraform/azure/README.md#install) and its Terraform sources.

> **Before starting:** this is a single-node deployment with plain HTTP and no persistent data disk. It is suitable for evaluating E2B, but needs additional networking, TLS, and operational design for sensitive production workloads.

## 1. Prepare the prerequisites

You need:

| Requirement | Details |
|---|---|
| Azure access | **Owner**, or **Contributor + User Access Administrator**, at the scope needed to create the resource group and role definitions/assignments |
| Terraform | Version **1.7.5 or newer** |
| Azure CLI | For authentication and troubleshooting |
| Git | Terraform uses it to download the repository module |
| Python | For testing the E2B SDK from your computer |
| Azure capacity | A supported nested-virtualization VM size and sufficient regional/family vCPU quota |

Install missing tools using their official installers, or Windows Package Manager:

```powershell
winget install --exact --id Microsoft.AzureCLI
winget install --exact --id Hashicorp.Terraform
winget install --exact --id Git.Git
```

Reopen PowerShell after installing, then check:

```powershell
az version
terraform version
git --version
python --version
```

**Docker is installed on the Azure VM automatically. You do not need Docker Desktop locally.**

## 2. Sign in and select your Azure subscription

```powershell
az login

az account list --output table

$SubscriptionId = "<YOUR-SUBSCRIPTION-ID>"
az account set --subscription $SubscriptionId

$env:ARM_SUBSCRIPTION_ID = $SubscriptionId

az account show --output table
```

`ARM_SUBSCRIPTION_ID` is important because the module uses AzureRM provider version 4.x.

Your account must be able to create **custom roles and role assignments**, not just VMs.

## 3. Check the region and VM size

The defaults are:

- Region: `eastus`
- Availability zone: `1`
- VM size: `Standard_D4ds_v7`
- RAM: 16 GiB
- OS: Ubuntu 24.04, x86-64
- OS disk: 50 GB Premium SSD

Check whether your subscription can use the default size:

```powershell
az vm list-skus `
  --location eastus `
  --resource-type virtualMachines `
  --size Standard_D4ds_v7 `
  --all `
  --query "[?name=='Standard_D4ds_v7'].{name:name,zones:locationInfo[0].zones,restrictions:restrictions}" `
  --output json
```

Check regional quota:

```powershell
az vm list-usage --location eastus --output table
```

Ensure zone `1` is available and no applicable subscription/zone restriction blocks the size.

If unavailable, select another supported size, such as `Standard_D4ds_v5`, **after checking its availability**. The [module's validation](https://github.com/e2b-dev/runtime/blob/9791dc8e1c78d459c29b23c57221c38d7318f80a/embed/terraform/azure/variables.tf) accepts certain Intel D-series v3+, AMD D-series v5+, and L-series v3+ sizes.

**Do not substitute a B-series or ARM/Cobalt VM.** E2B sandboxes require nested virtualization and `/dev/kvm`.

## 4. Create a local Terraform working directory

Use a directory outside OneDrive or other automatically synchronized folders: **Terraform state will contain secrets**.

```powershell
New-Item -ItemType Directory -Path "C:\e2b-azure" -Force
Set-Location "C:\e2b-azure"
```

Create `main.tf` with:

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
  type = list(string)
}

module "e2b" {
  source = "github.com/e2b-dev/runtime//embed/terraform/azure?ref=9791dc8e1c78d459c29b23c57221c38d7318f80a"

  name          = "e2b-embed-demo"
  location      = "eastus"
  zone          = "1"
  instance_size = "Standard_D4ds_v7"
  client_cidrs  = var.client_cidrs
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
```

Important details:

- The commit above was the repository's current `main` revision when checked on **October 14, 2026**. Pinning it makes the installation reproducible.
- `storage_use_azuread = true` is required: the module's storage account disables shared-key authentication.
- Use a different `name` for another installation in the same tenant, because custom role names must be unique.
- **Do not copy only the Azure module directory.** It references Compose files elsewhere in the repository. The GitHub module source downloads the necessary repository structure.
- The output blocks expose the module's values to `terraform output`.

## 5. Allow your client's public IP address

Find the public IPv4 address used by your workstation, browser, and SDK traffic:

```powershell
Invoke-RestMethod -Uri "https://api.ipify.org"
```

Create `terraform.tfvars`:

```hcl
client_cidrs = ["YOUR-PUBLIC-IPV4/32"]
```

Replace the placeholder with your actual IP; for example, the format is `198.51.100.7/32`, but **that example is not your IP**.

If other application servers need access, include their public outbound addresses:

```hcl
client_cidrs = [
  "YOUR-WORKSTATION-PUBLIC-IPV4/32",
  "YOUR-APPLICATION-OUTBOUND-IPV4/32"
]
```

Only the allowed CIDRs can reach:

| Port | Service |
|---|---|
| 3000 | E2B API |
| 3001 | Dashboard |
| 3002 | Sandbox traffic proxy |

**Do not use `0.0.0.0/0`.** VPNs, proxies, or changing home IP addresses may require adjusting this list. Port 22 is intentionally closed.

## 6. Deploy with Terraform

From `C:\e2b-azure`:

```powershell
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Review the plan, then enter `yes` to approve creation.

Terraform provisions the VM Scale Set, networking, **two public IPs**, NAT gateway, identity, storage account, and RBAC resources. The VM then installs Docker and starts E2B.

The README reports these measured timings:

| Milestone | Approximate timing |
|---|---|
| Terraform apply completes | 7 minutes after starting apply |
| API `/health` responds | 2 minutes after apply completes |
| First sandbox can start | 7 minutes after apply completes |

These are measurements, not guarantees. Allow roughly **15-20 minutes** for initial deployment and verification.

Azure charges apply for the VM, Premium disk, NAT gateway, public IPs, storage, and applicable traffic.

## 7. Configure your local SDK and verify the API

Set the environment variables in PowerShell:

```powershell
$env:E2B_API_URL = terraform output -raw api_url
$env:E2B_SANDBOX_URL = terraform output -raw sandbox_url
$env:E2B_API_KEY = terraform output -raw e2b_api_key
```

Check health:

```powershell
curl.exe --fail --show-error "$env:E2B_API_URL/health"
```

If the service is still starting, wait and retry. A successful health check **does not mean the initial `base` template build has finished**.

Open the dashboard:

```powershell
$DashboardUrl = terraform output -raw dashboard_url
Start-Process $DashboardUrl
```

Retrieve the key locally and paste it into the dashboard's key form:

```powershell
terraform output -raw e2b_api_key
```

Treat the key as a secret; do not paste it into shared logs or screenshots.

## 8. Create your first sandbox

Install the SDK version used by the README:

```powershell
python -m venv .venv

.\.venv\Scripts\python.exe -m pip install e2b==2.46.0
```

Create `test_e2b.py`:

```python
from e2b import Sandbox

sandbox = Sandbox.create("base")
try:
    result = sandbox.commands.run("echo hello from the sandbox")
    print(result.stdout)
finally:
    sandbox.kill()
```

Run it:

```powershell
.\.venv\Scripts\python.exe .\test_e2b.py
```

Expected output:

```text
hello from the sandbox
```

If you see:

```text
404: tag 'default' does not exist for template 'local-dev-team/base'
```

the initial template build may still be running. Wait a minute and retry. A template appearing in the API's template list is **not sufficient proof that its build is ready**.

## 9. Run the packaged smoke test and troubleshoot

The README's `run_command` output uses Bash syntax and `eval`. **Do not paste that command directly into PowerShell.** Use the equivalent Azure CLI commands:

```powershell
$ResourceGroup = "e2b-embed-demo"

$VmName = az vm list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --query "[0].name" `
  --output tsv
```

Check KVM and run the smoke test:

```powershell
az vm run-command invoke `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --name $VmName `
  --command-id RunShellScript `
  --scripts "set -e; ls -l /dev/kvm; cd /opt/e2b; docker compose --profile test run --rm smoke"
```

The packaged test checks sandbox creation and access to a port inside the sandbox.

For startup diagnostics:

```powershell
az vm run-command invoke `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --name $VmName `
  --command-id RunShellScript `
  --scripts "tail -n 100 /var/log/cloud-init-output.log; journalctl -u e2b-embed -n 100"
```

Review logs for secrets before sharing them.

| Symptom | What to check |
|---|---|
| Role creation/assignment denied | Owner, or Contributor + User Access Administrator permissions |
| `AuthorizationPermissionMismatch` during blob upload | RBAC propagation; the README recommends retrying `terraform apply` |
| VM SKU or zone deployment failure | Subscription restrictions, zone availability, and vCPU quota |
| API/dashboard connection timeout | Startup progress and the actual client public IP in `client_cidrs` |
| API healthy, sandbox creation fails initially | `base` template build may still be running |
| `/dev/kvm` missing | VM size does not expose the required nested virtualization |

## 10. Understand persistence and clean up

**Before relying on this deployment:**

- Traffic uses **plain HTTP**; CIDR restrictions do not encrypt API keys or sandbox traffic.
- Secrets exist in Terraform state and VM custom data. The README warns that Azure Reader access can expose the custom data.
- The storage account created by the module is **not a Terraform remote-state backend**. Configure a protected backend separately for shared or production operation.
- Automatic repair replaces an unhealthy VM with a fresh disk. Templates and local data are lost.
- Running `docker compose down` is not a safe pause: the health mechanism can replace the instance.

When finished with the installation:

```powershell
terraform plan -destroy
terraform destroy
```

Review and confirm the destruction. This removes the resource group and the resources created by this module; **VM-local templates and data will be lost**.
