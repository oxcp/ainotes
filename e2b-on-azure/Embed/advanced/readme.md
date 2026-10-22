# Install E2B Embed on Azure: Advanced Step-by-Step Guide (Bash)

**Bash guide** | [PowerShell guide](readme_powershell.md)

> [!tip]
> To set up E2B when the Azure Storage account permits public access, follow the quick install guide: [Bash](../quick-install.md) or [PowerShell](../quick-install-powershell.md).

Updated October 22, 2026. Commands use Bash on Ubuntu/Debian Linux unless otherwise indicated.

This Bash guide uses the vendored module's **existing-VNet mode**, matching the [PowerShell guide](readme_powershell.md). It deploys **E2B Embed on one Azure Linux VM**, managed by a single-instance VM Scale Set. Terraform creates the infrastructure, installs Docker, and starts the complete E2B stack automatically. You do not need AKS, an existing **E2B** VM, or an E2B Cloud account. You **do** need an existing VNet and a Linux VM or self-hosted runner on that VNet to execute Terraform.

This walkthrough is based on the upstream [Azure README](https://github.com/e2b-dev/runtime/blob/main/embed/terraform/azure/README.md#install) and the locally adapted module. It creates **two new subnets in the supplied VNet**: one for the E2B VM and one for a new Blob Private Endpoint to the deployed Storage Account. It creates **no VNet and no VNet peering**, and keeps Storage public network access disabled. The Blob Private DNS Zone and its **Private DNS Zone VNet link (DNS zone-to-VNet association)** can be created or reused using `terraform.tfvars`. This DNS association is distinct from Azure Private Link and the Blob Private Endpoint.

> **Before starting:** this is a single-node deployment with plain HTTP and no persistent data disk. It is suitable for evaluating E2B, but needs additional networking, TLS, and operational design for sensitive production workloads.

## 1. Prepare the prerequisites

You need:

| Requirement | Details |
|---|---|
| Azure access | **Owner**, or **Contributor + User Access Administrator**, at the scope needed to create the resource group and role definitions/assignments |
| Terraform | Version **1.7.5 or newer** |
| Azure CLI | For authentication and troubleshooting |
| Bash | Running on Ubuntu/Debian Linux |
| Git | For obtaining and tracking the vendored module |
| Python | For testing the E2B SDK; the examples use the `python3` command |
| Azure capacity | A supported nested-virtualization VM size and sufficient regional/family vCPU quota |
| Private-network execution | An existing Linux Azure VM or self-hosted Linux runner attached to a VNet in the same subscription |
| Available subnet space | Two unused, non-overlapping subnet CIDRs inside the existing VNet's address space, and two unused subnet names |
| VNet region | The existing VNet must be in the deployment region (`eastasia` in this guide) |

The deploying identity also needs permission to read the existing VNet, create/delete the two subnets, join them, and associate the VM subnet with the deployment's NSG and NAT gateway. By default, Terraform creates `privatelink.blob.core.windows.net` in the E2B resource group and associates that DNS zone with the supplied VNet through a Private DNS Zone VNet link. Reusing a Private DNS Zone requires permission to join that zone for the endpoint's DNS zone group and manage the endpoint's DNS records; creating a new Private DNS Zone VNet link also requires permission to manage that DNS association. Use a zone in the selected subscription for this walkthrough. The existing VNet, runner VM, other subnets, and other Storage Accounts' endpoints remain outside this deployment's ownership.

The deploying identity needs custom-role management permission in both resource groups and role-assignment permission on the new VM subnet. The module extends its custom role's assignable scopes to the VNet resource group and grants the VM identity subnet join at **only the new VM subnet**, so first-boot NIC/public-IP attachment works across resource groups. It does not grant the VM access to all existing subnets.

Use a **new, separate E2B resource group** (`name = "e2b-embed-demo"` below), not the existing VNet or shared DNS resource group. Terraform must not own a resource group containing shared infrastructure.

Run the examples in Bash, keeping these settings in the session:

```bash
set -euo pipefail
```

Check each command's output before continuing; do not proceed after a failed Azure CLI operation. A backslash used for line continuation must be the **last character on its line**, with no trailing spaces.

Install only the missing tools. For an Ubuntu/Debian runner needing all prerequisites:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git python3 python3-venv

curl -fsSL https://aka.ms/InstallAzureCLIDeb | sudo bash

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
curl --version
```

**Docker is installed on the E2B Azure VM automatically. You do not need to install Docker on the Terraform runner.**

## 2. Sign in and select your Azure subscription

Run these commands on the private-network runner:

```bash
az login

az account list --output table

SUBSCRIPTION_ID="<YOUR-SUBSCRIPTION-ID>"
az account set --subscription "$SUBSCRIPTION_ID"

export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"

az account show --output table
```

On a runner without an interactive browser, use `az login --use-device-code` if permitted by your organization's authentication policy.

`ARM_SUBSCRIPTION_ID` is required for the AzureRM 4.x provider. Exported variables are inherited by Terraform and Python launched from this session; they do not persist into a new shell. Repeat the setup if you reopen the shell.

Your account must be able to create **custom roles and role assignments**, not just VMs.

## 3. Check the region and VM size

The defaults are:

- Region: `eastasia`
- Availability zone: `1`
- VM size: `Standard_D4ds_v6`
- RAM: 16 GiB
- OS: Ubuntu 24.04, x86-64
- OS disk: 50 GB Premium SSD

Check whether your subscription can use the default size:

```bash
az vm list-skus \
  --location eastasia \
  --resource-type virtualMachines \
  --size Standard_D4ds_v6 \
  --all \
  --query "[?name=='Standard_D4ds_v6'].{name:name,zones:locationInfo[0].zones,restrictions:restrictions}" \
  --output json
```

Check regional quota:

```bash
az vm list-usage --location eastasia --output table
```

Ensure zone `1` is available and no applicable subscription/zone restriction blocks the size.

If `Standard_D4ds_v6` is unavailable, select another supported size, such as `Standard_D4ds_v7`, **after checking availability and quota in `eastasia`**. The [module's validation](https://github.com/e2b-dev/runtime/blob/f9b828e76e190abe75d1cdd2d58fff6f4688ca34/embed/terraform/azure/variables.tf) accepts certain Intel D-series v3+, AMD D-series v5+, and L-series v3+ sizes.

**Do not substitute a B-series or ARM/Cobalt VM.** E2B sandboxes require nested virtualization and `/dev/kvm`.

## 4. Create a local Terraform working directory

Use a directory outside OneDrive or other automatically synchronized folders: **Terraform state contains secrets**. These commands are for a **new** deployment:

```bash
SOURCE_DIRECTORY="/path/to/ainotes/e2b-on-azure/Embed/advanced"
DEPLOYMENT_DIRECTORY="$HOME/e2b-azure"

if [[ -e "$DEPLOYMENT_DIRECTORY" || -L "$DEPLOYMENT_DIRECTORY" ]]; then
  printf 'Deployment directory already exists: %s. Use its existing state or choose a new empty directory.\n' "$DEPLOYMENT_DIRECTORY" >&2
  exit 1
fi
mkdir -- "$DEPLOYMENT_DIRECTORY"
cp -- "$SOURCE_DIRECTORY/main.tf" "$DEPLOYMENT_DIRECTORY/"
cp -R -- "$SOURCE_DIRECTORY/runtime" "$DEPLOYMENT_DIRECTORY/"
cd -- "$DEPLOYMENT_DIRECTORY"
```

Replace `SOURCE_DIRECTORY` with your local checkout's `e2b-on-azure/Embed/advanced` directory. Confirm that `DEPLOYMENT_DIRECTORY` is not synchronized before running the copy commands.

Keep `main.tf` and `runtime` in the same working directory. Run Terraform from `DEPLOYMENT_DIRECTORY`; create tfvars and keep state there.

Copy the **complete** `runtime` tree, including its Compose files and `.env`. Do not copy only the Azure module directory. Use this directory's [main.tf](main.tf), not the public-access configuration in [../main.tf](../main.tf).

For a deployment that already failed partway through, use the **original deployment directory and state**, not a fresh directory. Back up and securely transfer the existing `terraform.tfstate` (if using local state), `.terraform.lock.hcl`, variable files, and backend configuration to the runner. Do not transfer the machine-specific `.terraform` provider cache; run `terraform init` on the runner. State contains secrets and must not be committed or uploaded to a public location.

The module call stays named `e2b`, preserving unchanged `module.e2b.*` resource addresses. **This is not an in-place migration from the old dedicated-VNet topology.** Switching an existing deployment to `existing_vnet` can destroy its old VNet/peerings and replace subnets or compute. Plan a migration separately; do not approve such changes for an in-use deployment.

The copied [main.tf](main.tf) already contains the **complete configuration below**; no replacement is needed. Keep this code block synchronized with that file. It requires `existing_vnet` (no fallback to creating a VNet), uses `eastasia`, and exposes subnet names and prefixes through tfvars. Change `location` if your existing VNet is in another region, and repeat the capacity checks for that region. The HCL syntax is the same in Bash and PowerShell; keep Terraform module paths in their existing form.

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

variable "existing_vnet" {
  description = "Existing VNet for the new E2B VM and Private Endpoint subnets."
  type = object({
    name                = string
    resource_group_name = string
  })
  nullable = false
}

variable "e2b_vm_subnet_name" {
  description = "Unused name for the new E2B VM subnet."
  type        = string
  default     = "e2b-vm"
}

variable "e2b_vm_subnet_prefixes" {
  description = "Unused address prefixes inside the existing VNet for the E2B VM subnet."
  type        = list(string)
}

variable "private_endpoint_subnet_name" {
  description = "Unused name for the new Blob Private Endpoint subnet."
  type        = string
  default     = "e2b-private-endpoints"
}

variable "private_endpoint_subnet_prefixes" {
  description = "Unused address prefixes inside the existing VNet for the Blob Private Endpoint subnet."
  type        = list(string)
}

variable "blob_private_dns_zone_id" {
  description = "Existing privatelink.blob.core.windows.net zone already associated with existing_vnet via a Private DNS Zone VNet link. Leave null to create the zone and its DNS association."
  type        = string
  default     = null
  nullable    = true
}

module "e2b" {
  source = "./runtime/embed/terraform/azure"

  name                             = "e2b-embed-demo"
  location                         = "eastasia"
  zone                             = "1"
  instance_size                    = "Standard_D4ds_v6"
  client_cidrs                     = var.client_cidrs
  existing_vnet                    = var.existing_vnet
  vm_subnet_name                   = var.e2b_vm_subnet_name
  vm_subnet_prefixes               = var.e2b_vm_subnet_prefixes
  private_endpoint_subnet_name     = var.private_endpoint_subnet_name
  private_endpoint_subnet_prefixes = var.private_endpoint_subnet_prefixes
  blob_private_dns_zone_id         = var.blob_private_dns_zone_id
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

## 5. Configure the existing VNet, new subnets, and Private DNS

First inspect the supplied VNet and existing subnets:

```bash
VNET_RESOURCE_GROUP="<EXISTING-VNET-RESOURCE-GROUP>"
VNET_NAME="<EXISTING-VNET-NAME>"

az network vnet show --resource-group "$VNET_RESOURCE_GROUP" --name "$VNET_NAME" \
  --query "{id:id,location:location,addressSpace:addressSpace.addressPrefixes,dnsServers:dhcpOptions.dnsServers}" --output json
az network vnet subnet list --resource-group "$VNET_RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
  --query "[].{name:name,prefix:addressPrefix,prefixes:addressPrefixes}" --output table
```

Reserve two unused CIDRs inside this VNet, not overlapping any existing subnet or each other. This guide always creates new subnets, even when other Storage Accounts already have Private Endpoints in the VNet. Do not import or reuse their subnets for this deployment. If another Terraform stack manages the VNet with inline `subnet` blocks, coordinate ownership first: inline subnet management conflicts with separately managed `azurerm_subnet` resources.

On each workstation or application host that will access E2B, find its outbound public IPv4 address:

```bash
curl -4fsS https://api.ipify.org
echo
```

If your browser or SDK runs on a different machine from the runner, allow that machine's outbound IP as well, not just the runner's IP.

Back in the deployment directory on the runner, create `terraform.tfvars` after replacing the placeholders:

```bash
cat > terraform.tfvars <<'EOF'
existing_vnet = {
  name                = "YOUR-EXISTING-VNET-NAME"
  resource_group_name = "YOUR-EXISTING-VNET-RESOURCE-GROUP"
}

e2b_vm_subnet_name               = "e2b-vm"
e2b_vm_subnet_prefixes           = ["YOUR-UNUSED-VM-SUBNET-CIDR"]
private_endpoint_subnet_name    = "e2b-private-endpoints"
private_endpoint_subnet_prefixes = ["YOUR-UNUSED-PRIVATE-ENDPOINT-SUBNET-CIDR"]

# Case A: no existing Blob Private DNS Zone to reuse.
blob_private_dns_zone_id = null

client_cidrs = ["YOUR-PUBLIC-IPV4/32"]
EOF
```

This writes a new variable file; **edit rather than overwrite** an existing deployment's file. The quoted heredoc delimiter preserves literal HCL. Save the file as UTF-8, and put the closing `EOF` at the beginning of its line.

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

For example, **only if** the existing VNet contains `10.10.0.0/16` and these ranges are unused:

```hcl
e2b_vm_subnet_prefixes           = ["10.10.0.0/25"]
private_endpoint_subnet_prefixes = ["10.10.0.128/26"]
```

No VNet address-space change or peering is performed. Existing DNS servers and existing subnet settings are not changed.

### Choose the DNS case in terraform.tfvars

The following are different Azure concepts:

| Term | Meaning in this guide |
|---|---|
| **Private DNS Zone VNet link** | A DNS zone-to-VNet association (`azurerm_private_dns_zone_virtual_network_link`). It makes the zone available for DNS resolution from that VNet through Azure DNS; it is **not** a Storage private network connection and creates no Private Endpoint. |
| **Azure Private Link / Blob Private Endpoint** | Azure Private Link provides private connectivity to the Storage service through a Blob Private Endpoint (`azurerm_private_endpoint`) with a private IP in a VNet subnet. This deployment always creates a new endpoint for its new Storage Account. |
| **Private Endpoint DNS zone group** | Associates the new Private Endpoint with the chosen DNS zone and maintains the endpoint's DNS record. It does **not** replace the DNS zone-to-VNet association. |

Private Endpoints connect to individual Storage Accounts; **an endpoint for another account cannot be reused for the new account**. A single `privatelink.blob.core.windows.net` zone can hold records for multiple accounts.

For this existing-VNet guide, supplying `blob_private_dns_zone_id` means **reuse a zone already associated with the supplied VNet through an existing Private DNS Zone VNet link**. There is no separate switch for creating this DNS association. This does **not** mean reusing another Storage Account's Private Endpoint.

| Case | `blob_private_dns_zone_id` | Terraform behavior |
|---|---|---|
| A: no existing Blob zone | `null` | Create the zone, its Private DNS Zone VNet link (DNS association), and the new endpoint's DNS zone group |
| B: existing zone already associated with this VNet | Existing zone resource ID | Reuse the zone and its Private DNS Zone VNet link without creating either; create the new endpoint's DNS zone group/record |

Both cases create a **new Blob Private Endpoint** for this deployment's Storage Account. A Private DNS Zone is an independent Azure resource, not a resource inside a VNet: its existence alone does not guarantee a DNS zone-to-VNet association. If that association is missing, have the zone owner create a Private DNS Zone VNet link before using Case B. This guide does not manage that existing DNS association.

For **Case B**, set:

```hcl
blob_private_dns_zone_id = "/subscriptions/<SUBSCRIPTION-ID>/resourceGroups/<DNS-RESOURCE-GROUP>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
```

Before choosing Case B, check the intended shared zone and its Private DNS Zone VNet links (DNS associations, not Private Endpoints):

```bash
DNS_RESOURCE_GROUP="<DNS-RESOURCE-GROUP>"
BLOB_ZONE_NAME="privatelink.blob.core.windows.net"

az network private-dns zone show --resource-group "$DNS_RESOURCE_GROUP" --name "$BLOB_ZONE_NAME" \
  --query id --output tsv
az network private-dns link vnet list --resource-group "$DNS_RESOURCE_GROUP" --zone-name "$BLOB_ZONE_NAME" \
  --query "[].{name:name,vnet:virtualNetwork.id,state:virtualNetworkLinkState}" --output table
```

For Case B, confirm the Private DNS Zone VNet link targets the **exact supplied VNet ID** and is completed. Existing Private Endpoints alone do not prove that the correct zone is associated with the VNet. Do not associate a second same-name zone with this VNet. If the zone is centrally managed, get its ID and DNS association status from its owner; a failed lookup is not evidence that no zone exists.

The endpoint's `private_dns_zone_group` automatically creates the new account's A record (`<new-account>` -> endpoint private IP) in the selected zone and manages its lifecycle. **Do not add a duplicate `azurerm_private_dns_a_record` or manually overwrite records.** Existing records for other Storage Accounts and their endpoints are not imported or modified. Keep the zone ID stable after deployment: changing a Terraform-created DNS zone or Private DNS Zone VNet link to external ownership requires a deliberate state migration, not simply changing tfvars.

**Upgrading an earlier copy:** update both `main.tf` and the vendored Azure module, and remove the obsolete `link_vnet_to_blob_private_dns_zone` setting from tfvars/module calls. Use the original state and inspect `terraform plan`. With an existing zone ID, a Private DNS Zone VNet link previously owned by this deployment would now be planned for deletion. Do not delete that shared DNS association; arrange an explicit state-ownership handoff first. No state migration is needed for an externally managed Private DNS Zone VNet link that was never recorded in this deployment's state. This warning concerns the DNS zone-to-VNet association, not the Blob Private Endpoint.

### Storage Private Link and the bootstrap sequence

`client_cidrs` controls the E2B API, dashboard, and sandbox proxy, not Storage access.

The selected topology is:

```text
Existing VNet (eastasia; address space unchanged)
    |-- existing runner subnet --> Linux Terraform runner VM (unchanged)
    |-- existing subnets / other Storage Private Endpoints (unchanged)
    |-- NEW e2b-vm subnet --> Ubuntu E2B VMSS
    |
    `-- NEW e2b-private-endpoints subnet
          |
          v
        Blob Private Endpoint --> Storage Account (public access disabled)

privatelink.blob.core.windows.net (new or reused)
    | Private DNS Zone VNet link: DNS association to existing VNet (new or reused)
    ` NEW A record: deployed Storage Account --> new endpoint private IP
```

The runner does not need the Storage Account to exist first. It needs Azure credentials, access to management/authentication endpoints, and attachment to the supplied VNet. Terraform reads that VNet and creates only the new subnets, Storage Account, Private Endpoint, DNS zone group, and any requested DNS zone and Private DNS Zone VNet link through the management API. No existing Private Endpoint is required.

The two Blob uploads wait for these resources, a 60-second private-network propagation delay, and RBAC propagation. Only after uploading the files does Terraform start the E2B VMSS in the VM subnet. This avoids relying on an E2B VM that cannot boot until its Compose files exist, without opening Storage publicly.

The 60-second delay is not proof of connectivity. NSGs, routes, DNS caches, and custom DNS must permit the runner to resolve and reach the endpoint on TCP 443. With custom DNS, configure conditional forwarding for `blob.core.windows.net` through an Azure DNS Private Resolver inbound endpoint in a VNet linked to the Blob private zone, or an equivalent Azure DNS forwarding path. This must resolve the public hostname's `privatelink.blob.core.windows.net` alias to the private A record. Keep using `<account>.blob.core.windows.net`, not a `privatelink` URL or an IP address.

## 6. Deploy with Terraform

Run in the deployment directory **on the Linux VM in the supplied existing VNet**, authenticated as in step 2 with `ARM_SUBSCRIPTION_ID` set. An ordinary machine outside the private DNS/network path cannot perform the Blob data-plane operations.

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Review the plan and enter `yes` to approve creation. For an earlier deployment, migrate/import state where appropriate rather than accepting unexpected replacement of an in-use VNet, VMSS, or Storage Account.

Verify the plan creates **zero VNets and zero peerings**, creates the two subnets in the **existing VNet's resource group**, and places the VMSS and Blob Private Endpoint in those subnets. It also provisions **two public IPs**, a NAT gateway associated only with the new VM subnet, an NSG, identity, Storage Account, and RBAC resources. DNS zone and Private DNS Zone VNet link creation must match Case A or B. Existing subnets, Private Endpoints, DNS zones, and DNS zone-to-VNet associations must not be scheduled for replacement or deletion. The Ubuntu VM then installs Docker and starts E2B.

| Milestone | Approximate upstream timing |
|---|---|
| Terraform apply completes | 7 minutes after starting apply |
| API `/health` responds | 2 minutes after apply completes |
| First sandbox can start | 7 minutes after apply completes |

These are measurements from the original upstream deployment, not guarantees. The local Private Link configuration adds a 60-second network propagation wait and may take longer. Allow roughly **15-20 minutes** or more for initial deployment and verification.

Charges apply for the VM, Premium disk, NAT gateway, public IPs, storage, Private Endpoint, DNS, and applicable traffic. This deployment creates no peering.

After apply, verify private DNS and authenticated Blob access from the runner:

```bash
STORAGE_ACCOUNT="$(terraform output -raw storage_account_name)"
EXPECTED_PRIVATE_IP="$(terraform output -raw blob_private_endpoint_ip)"
BLOB_HOST_NAME="${STORAGE_ACCOUNT}.blob.core.windows.net"

getent ahostsv4 "$BLOB_HOST_NAME"
printf 'Expected private endpoint IP: %s\n' "$EXPECTED_PRIVATE_IP"
if timeout 10 bash -c 'exec 3<>"/dev/tcp/$1/443"' _ "$BLOB_HOST_NAME"; then
  printf 'TCP 443 connection succeeded.\n'
else
  printf 'TCP 443 connection failed. Check DNS, routes, NSGs and endpoint approval.\n' >&2
  exit 1
fi

az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name compose \
  --auth-mode login \
  --query "[].name" \
  --output json
```

The service hostname must resolve to the expected private IP, the TCP test must succeed, and the Blob list should contain `compose.yaml` and `.env`.

## 7. Configure your local SDK and verify the API

From the deployment directory, set the environment variables. Assign values before exporting so a failed Terraform command is not masked by `export`:

```bash
E2B_API_URL="$(terraform output -raw api_url)"
E2B_SANDBOX_URL="$(terraform output -raw sandbox_url)"
E2B_API_KEY="$(terraform output -raw e2b_api_key)"
export E2B_API_URL E2B_SANDBOX_URL E2B_API_KEY
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

Open that URL in a browser. If the runner has no browser, use an allowed workstation. Retrieve the key locally and paste it into the dashboard's key form:

```bash
terraform output -raw e2b_api_key
```

Treat it as a secret; do not put it in shared logs, transcripts, screenshots, or source control. If running the SDK elsewhere, set the same three environment variables securely in that machine's shell without copying Terraform state there, and ensure its outbound IP is allowed.

## 8. Create your first sandbox

Install the SDK version used by the PowerShell guide:

```bash
python3 -m venv .venv

.venv/bin/python -m pip install e2b==2.46.0
```

Calling the virtual environment's interpreter directly avoids activating the environment.

Create `test_e2b.py`:

```bash
cat > test_e2b.py <<'EOF'
from e2b import Sandbox

sandbox = Sandbox.create("base")
try:
    result = sandbox.commands.run("echo hello from the sandbox")
    print(result.stdout)
finally:
    sandbox.kill()
EOF
```

Run in the same session where the E2B environment variables were set:

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
if [[ -z "${VM_NAME//[[:space:]]/}" ]]; then
  printf 'No VM found in resource group %s. Check deployment status.\n' "$RESOURCE_GROUP" >&2
  exit 1
fi
```

If you changed the module's `name`, adjust `RESOURCE_GROUP`. Use the subscription selected in step 2.

Check KVM and run the smoke test:

```bash
az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts 'set -e; ls -l /dev/kvm; cd /opt/e2b; docker compose --profile test run --rm smoke'
```

The packaged test checks sandbox creation and access to a port inside the sandbox. Inspect Run Command's returned stdout/stderr and script exit status; successful submission alone does not prove the smoke test passed.

For startup diagnostics:

```bash
az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts 'tail -n 100 /var/log/cloud-init-output.log; journalctl -u e2b-embed -n 100'
```

Azure executes the `--scripts` strings on the deployed Ubuntu VM, not on the runner. Single quotes prevent the local shell from expanding variables in those strings. Review logs for secrets before sharing.

| Symptom | What to check |
|---|---|
| Role creation/assignment denied | Owner, or Contributor + User Access Administrator permissions |
| `AuthorizationPermissionMismatch` during Blob upload | RBAC propagation; retry `terraform apply` after propagation |
| Blob 403 or timeout with public access disabled | Use the private runner; verify the Private DNS Zone VNet link (DNS association), new account's A record, Private Endpoint approval, subnet routes/NSGs, and TCP 443. Do not enable public access to bypass organizational policy |
| Subnet creation conflict | Use unused names and CIDRs inside the existing VNet; check for another stack managing inline subnets |
| Private DNS Zone VNet link already exists or namespace overlap | Supply the correct existing zone ID after verifying its DNS association with this VNet. The module skips creating that DNS association, not the new Blob Private Endpoint; update older deployment copies if they still attempt it |
| VM SKU or zone deployment failure | Subscription restrictions, zone availability, and vCPU quota |
| API/dashboard connection timeout | Startup progress and the actual client public IP in `client_cidrs` |
| API healthy, sandbox creation fails initially | `base` template build may still be running |
| `/dev/kvm` missing | VM size does not expose the required nested virtualization |
| Bash continuation or heredoc errors | Use Bash, no spaces after continuation backslashes, UTF-8 files, and an unindented closing `EOF` |

## 10. Understand persistence and clean up

**Before relying on this deployment:**

- Traffic uses **plain HTTP**; CIDR restrictions do not encrypt API keys or sandbox traffic.
- Secrets exist in Terraform state and VM custom data. The README warns that Azure Reader access can expose the custom data.
- The storage account created by the module is **not a Terraform remote-state backend**. Configure a protected backend separately for shared or production operation.
- Automatic repair replaces an unhealthy VM with a fresh disk. Templates and local data are lost.
- Running `docker compose down` is not a safe pause: the health mechanism can replace the instance.

When finished, run from the original deployment directory:

```bash
terraform plan -destroy
terraform destroy
```

Destroy from the private runner while its network and DNS path remain intact. Review and confirm destruction. This removes the E2B resource group, **only the two new subnets** in the existing VNet, the new Private Endpoint and its DNS zone group/A record, and any DNS zone and Private DNS Zone VNet link created by this deployment. No existing VNet or peering is owned or deleted. **VM-local templates and data will be lost.**

The existing runner VM, VNet, other subnets, and other Storage Accounts' Private Endpoints/records remain. In Case B, the supplied existing Private DNS Zone and its Private DNS Zone VNet link (DNS association) remain outside this deployment's state. In Case A, the created DNS zone and its Private DNS Zone VNet link are removed during destroy. Do not let unrelated resources depend on a zone or subnet owned by this deployment without first transferring ownership.

Clear the SDK credentials from this Bash session when no longer needed:

```bash
unset E2B_API_KEY E2B_API_URL E2B_SANDBOX_URL
```
