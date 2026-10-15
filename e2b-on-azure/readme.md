# Install E2B Embed on Azure: Step-by-Step Guide

> [!tip]
> To setup when Azure storage account permits public access, follow [Bash](e2b_on_azure_blob_public_access_bash.md) or [PowerShell](e2b_on_azure_blob_public_access_powershell.md).

Updated October 15, 2026. Commands use Bash on Ubuntu/Debian Linux unless otherwise indicated.

The linked module deploys **E2B Embed on one Azure Linux VM**, managed by a single-instance VM Scale Set. Terraform creates the infrastructure, installs Docker, and starts the complete E2B stack automatically. **You do not need AKS, an existing VM, or an E2B Cloud account.**

This walkthrough is based on the [Azure README](https://github.com/e2b-dev/runtime/blob/main/embed/terraform/azure/README.md#install) and its Terraform sources. The vendored module has been adapted to create a dedicated `e2bvnet`, peer it with the VNet that contains the Terraform runner, and keep Azure Storage public network access disabled by using Blob Private Link.

> **Before starting:** this is a single-node deployment with plain HTTP and no persistent data disk. It is suitable for evaluating E2B, but needs additional networking, TLS, and operational design for sensitive production workloads.

## 1. Prepare the prerequisites

You need:

| Requirement | Details |
|---|---|
| Azure access | **Owner**, or **Contributor + User Access Administrator**, at the scope needed to create the resource group and role definitions/assignments |
| Terraform | Version **1.7.5 or newer** |
| Azure CLI | For authentication and troubleshooting |
| Git | Recommended for tracking the vendored module and your Terraform changes |
| Python | For testing the E2B SDK from your computer |
| Azure capacity | A supported nested-virtualization VM size and sufficient regional/family vCPU quota |
| Private-network execution | An existing Azure VM or self-hosted runner attached to a VNet in the same subscription |
| Non-overlapping address space | A CIDR for `e2bvnet` that does not overlap the runner VNet or connected networks |

The deploying identity also needs permission to read the existing runner VNet and create a peering on it. By default, Terraform creates `privatelink.blob.core.windows.net` in the E2B resource group and links both VNets. If you reuse an existing Private DNS Zone, the identity also needs permission to create links and endpoint records in that zone. The runner VM and runner VNet remain outside this deployment's ownership.

Install the required packages, Azure CLI, and Terraform:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git python3 python3-venv

curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

curl -fsSL https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(. /etc/os-release && echo "$VERSION_CODENAME") main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

sudo apt-get update
sudo apt-get install -y terraform
```

Check the installed versions:

```bash
az version
terraform version
git --version
python3 --version
```

**Docker is installed on the E2B Azure VM automatically. You do not need to install Docker on the Terraform runner.**

## 2. Sign in and select your Azure subscription

```bash
az login

az account list --output table

SUBSCRIPTION_ID="<YOUR-SUBSCRIPTION-ID>"
az account set --subscription "$SUBSCRIPTION_ID"

export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"

az account show --output table
```

`ARM_SUBSCRIPTION_ID` is important because the module uses AzureRM provider version 4.x.

Your account must be able to create **custom roles and role assignments**, not just VMs.

## 3. Check the region and VM size

The defaults are:

- Region: `southeastasia`
- Availability zone: `1`
- VM size: `Standard_D4ds_v7`
- RAM: 16 GiB
- OS: Ubuntu 24.04, x86-64
- OS disk: 50 GB Premium SSD

Check whether your subscription can use the default size:

```bash
az vm list-skus \
  --location southeastasia \
  --resource-type virtualMachines \
  --size Standard_D4ds_v7 \
  --all \
  --query "[?name=='Standard_D4ds_v7'].{name:name,zones:locationInfo[0].zones,restrictions:restrictions}" \
  --output json
```

Check regional quota:

```bash
az vm list-usage --location southeastasia --output table
```

Ensure zone `1` is available and no applicable subscription/zone restriction blocks the size.

If unavailable, select another supported size, such as `Standard_D4ds_v5`, **after checking its availability**. The [module's validation](https://github.com/e2b-dev/runtime/blob/f9b828e76e190abe75d1cdd2d58fff6f4688ca34/embed/terraform/azure/variables.tf) accepts certain Intel D-series v3+, AMD D-series v5+, and L-series v3+ sizes.

**Do not substitute a B-series or ARM/Cobalt VM.** E2B sandboxes require nested virtualization and `/dev/kvm`.

## 4. Create a local Terraform working directory

Use a directory outside OneDrive or other automatically synchronized folders: **Terraform state will contain secrets**.

```bash
mkdir -p "$HOME/e2b-azure"
cd "$HOME/e2b-azure"
```

Copy this guide's `main.tf` and the complete `runtime` directory into the working directory. The vendored files are based on upstream commit `f9b828e76e190abe75d1cdd2d58fff6f4688ca34` and include the Compose files required by the module. Do not copy `main_blob_public_access.tf` into the same working directory: Terraform loads every `*.tf` file and the old example would duplicate the module, provider, variables, and outputs.

For a deployment that already failed partway through, use the **original deployment directory and state**, not a fresh directory. Back up and securely transfer the existing `terraform.tfstate` (if using local state), `.terraform.lock.hcl`, variable files, and backend configuration to the runner. Do not transfer the machine-specific `.terraform` provider cache; run `terraform init` on the runner. State contains secrets and must not be committed or uploaded to a public location.

The module call remains named `e2b`, so unchanged resources keep their `module.e2b.*` Terraform addresses. The VNet name and subnet layout intentionally change in this version; review the plan and state carefully before applying it to an existing deployment.

Use `main.tf` with:

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

  name                                      = "e2b-embed-demo"
  location                                  = "southeastasia"
  zone                                      = "1"
  instance_size                             = "Standard_D4ds_v7"
  client_cidrs                              = var.client_cidrs
  vnet_name                                 = "e2bvnet"
  vnet_address_space                        = var.e2b_vnet_address_space
  vm_subnet_name                            = "e2b-vm"
  vm_subnet_prefixes                        = var.e2b_vm_subnet_prefixes
  private_endpoint_subnet_name              = "private-endpoints"
  private_endpoint_subnet_prefixes          = var.private_endpoint_subnet_prefixes
  runner_vnet_name                          = var.runner_vnet_name
  runner_vnet_resource_group_name           = var.runner_vnet_resource_group_name
  blob_private_dns_zone_id                  = var.blob_private_dns_zone_id
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

- The vendored module is based on upstream commit `f9b828e76e190abe75d1cdd2d58fff6f4688ca34`, checked on **October 15, 2026**. Reapplying the network and Private Link changes is required when upgrading the vendored module.
- `storage_use_azuread = true` is required: the module's storage account disables shared-key authentication.
- Use a different `name` for another installation in the same tenant, because custom role names must be unique.
- **Do not copy only the Azure module directory.** It references `runtime/embed/compose/compose.yaml` and `.env`, which are included in the vendored `runtime` tree.
- The output blocks expose the module's values to `terraform output`.

## 5. Configure the runner VNet, E2B network, and client CIDRs

Find the public IPv4 address used by your workstation, browser, and SDK traffic:

```bash
curl -4fsS https://api.ipify.org
echo
```

Create `terraform.tfvars`. Replace the runner VNet values and public client IP:

```hcl
runner_vnet_name                = "YOUR-RUNNER-VNET-NAME"
runner_vnet_resource_group_name = "YOUR-RUNNER-VNET-RESOURCE-GROUP"

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

The default E2B network layout is:

```hcl
e2b_vnet_address_space           = ["10.10.0.0/24"]
e2b_vm_subnet_prefixes           = ["10.10.0.0/25"]
private_endpoint_subnet_prefixes = ["10.10.0.128/26"]
```

Change all three values together if `10.10.0.0/24` overlaps the runner VNet, a peered VNet, VPN/ExpressRoute routes, or an on-premises network. Azure rejects peering between overlapping address spaces.

By default, the deployment creates `privatelink.blob.core.windows.net` and links both VNets. To reuse an existing zone, add:

```hcl
blob_private_dns_zone_id = "/subscriptions/<SUBSCRIPTION-ID>/resourceGroups/<DNS-RESOURCE-GROUP>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
```

If the runner VNet is already linked to that exact zone and the link is managed elsewhere, also set:

```hcl
link_runner_vnet_to_blob_private_dns_zone = false
```

### Storage Private Link and the bootstrap sequence

`client_cidrs` controls the E2B API, dashboard, and sandbox proxy, not Storage access.

The selected topology is:

```text
Existing Terraform runner VM in its VNet
    |
    | Bidirectional global VNet peering
    v
E2B VNet (southeastasia, 10.10.0.0/24)
    |-- e2b-vm (10.10.0.0/25) --> E2B VMSS
    |
    `-- private-endpoints (10.10.0.128/26)
          |
          v
        Blob Private Endpoint --> Storage Account (public access disabled)

privatelink.blob.core.windows.net
    | Link: runner VNet
    ` Link: E2B VNet
```

The runner VM does **not** need the Storage Account to exist before it can be prepared. It only needs Azure credentials, access to Azure management/authentication endpoints, and attachment to the configured runner VNet. Terraform first creates `e2bvnet`, both subnets, both peering directions, the Storage Account, Private Endpoint, DNS zone group, and DNS links through Azure's management API. The two Blob uploads wait for those resources, a 60-second private-network propagation delay, and RBAC propagation. Only after the files are uploaded does the E2B VM Scale Set start in the `e2b-vm` subnet.

This avoids a dependency on an E2B VM that cannot boot until its Compose files are uploaded. It does not open Storage to the public internet. A 60-second wait is a propagation allowance, not proof of end-to-end connectivity; NSGs, routes, DNS caches, or custom DNS must still permit the runner to resolve and reach the private endpoint on TCP 443.

If the runner VNet uses custom DNS, configure conditional forwarding for `privatelink.blob.core.windows.net` through Azure DNS Private Resolver or an equivalent resolver path. Continue using `<account>.blob.core.windows.net`; do not replace the service URL with a `privatelink` URL or IP address.

## 6. Deploy with Terraform

Run from the deployment directory **on the VM in the configured runner VNet**, after setting `ARM_SUBSCRIPTION_ID` and authenticating on that machine as in step 2. An ordinary machine outside the peered/private DNS path cannot perform the Blob data-plane operations after public access is disabled.

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Review the plan, then enter `yes` to approve creation.

If updating an earlier deployment, the network resource addresses changed from the unmodified upstream module. Review the plan carefully and migrate/import state where appropriate instead of accepting unexpected replacement of an in-use VNet, VMSS, or Storage Account.

Terraform provisions `e2bvnet`, the VM and Private Endpoint subnets, bidirectional VNet peering, the VM Scale Set, **two public IPs**, NAT gateway, identity, storage account, RBAC resources, Blob private endpoint, and Private DNS links. It creates the Private DNS Zone unless `blob_private_dns_zone_id` points to an existing one. The VM then installs Docker and starts E2B.

The README reports these measured timings:

| Milestone | Approximate timing |
|---|---|
| Terraform apply completes | 7 minutes after starting apply |
| API `/health` responds | 2 minutes after apply completes |
| First sandbox can start | 7 minutes after apply completes |

These are measurements from the original upstream deployment, not guarantees. The local Private Link configuration adds a 60-second network propagation wait and may take longer. Allow roughly **15-20 minutes** or more for initial deployment and verification.

Azure charges apply for the VM, Premium disk, NAT gateway, public IPs, storage, Private Endpoint, and applicable traffic including global VNet peering.

After apply, verify private DNS and authenticated Blob access from the runner:

```bash
STORAGE_ACCOUNT="$(terraform output -raw storage_account_name)"
EXPECTED_PRIVATE_IP="$(terraform output -raw blob_private_endpoint_ip)"

getent ahostsv4 "${STORAGE_ACCOUNT}.blob.core.windows.net"
printf 'Expected private endpoint IP: %s\n' "$EXPECTED_PRIVATE_IP"

az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name compose \
  --auth-mode login \
  --query "[].name" \
  --output json
```

The service hostname must resolve to the endpoint's private IP, and the Blob list should contain `compose.yaml` and `.env`.

## 7. Configure your local SDK and verify the API

Set the environment variables:

```bash
export E2B_API_URL="$(terraform output -raw api_url)"
export E2B_SANDBOX_URL="$(terraform output -raw sandbox_url)"
export E2B_API_KEY="$(terraform output -raw e2b_api_key)"
```

Check health:

```bash
curl --fail --show-error "$E2B_API_URL/health"
```

If the service is still starting, wait and retry. A successful health check **does not mean the initial `base` template build has finished**.

Open the dashboard:

```bash
DASHBOARD_URL="$(terraform output -raw dashboard_url)"
printf 'Open the dashboard in your browser: %s\n' "$DASHBOARD_URL"
```

Retrieve the key locally and paste it into the dashboard's key form:

```bash
terraform output -raw e2b_api_key
```

Treat the key as a secret; do not paste it into shared logs or screenshots.

## 8. Create your first sandbox

Install the SDK version used by the README:

```bash
python3 -m venv .venv

.venv/bin/python -m pip install e2b==2.46.0
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

```bash
.venv/bin/python ./test_e2b.py
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

Set the resource group and look up the current VMSS instance:

```bash
RESOURCE_GROUP="e2b-embed-demo"

VM_NAME="$(
  az vm list \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[0].name" \
    --output tsv
)"
```

Check KVM and run the smoke test:

```bash
az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "set -e; ls -l /dev/kvm; cd /opt/e2b; docker compose --profile test run --rm smoke"
```

The packaged test checks sandbox creation and access to a port inside the sandbox.

For startup diagnostics:

```bash
az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "tail -n 100 /var/log/cloud-init-output.log; journalctl -u e2b-embed -n 100"
```

Review logs for secrets before sharing them.

| Symptom | What to check |
|---|---|
| Role creation/assignment denied | Owner, or Contributor + User Access Administrator permissions |
| `AuthorizationPermissionMismatch` during blob upload | RBAC propagation; the README recommends retrying `terraform apply` |
| Blob 403 or timeout with public access disabled | Execute from the private runner; verify private DNS, both peerings, endpoint approval, routing, and TCP 443. Do not enable public access to work around organizational policy |
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

```bash
terraform plan -destroy
terraform destroy
```

Run destroy from the private runner while its network and DNS path are intact. Review and confirm the destruction. This removes the E2B resource group, `e2bvnet`, both subnets, the Private Endpoint, both peering directions, and DNS links created by this deployment; **VM-local templates and data will be lost**. The existing runner VM and runner VNet remain. An existing Private DNS Zone supplied through `blob_private_dns_zone_id`, and any runner DNS link excluded with `link_runner_vnet_to_blob_private_dns_zone = false`, remain outside this deployment's state.
