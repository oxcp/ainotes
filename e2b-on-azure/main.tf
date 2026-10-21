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
  default     = null
}

variable "runner_vnet_resource_group_name" {
  description = "Resource group of the existing VNet containing the VM that runs Terraform."
  type        = string
  default     = null
}

variable "existing_vnet" {
  description = "Existing VNet for new E2B subnets; when set, no VNet or peering is created."
  type = object({
    name                = string
    resource_group_name = string
  })
  default = null
}

variable "link_vnet_to_blob_private_dns_zone" {
  description = "Create the Blob DNS link to the E2B VNet; false reuses an externally managed link."
  type        = bool
  default     = true
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
  instance_size                             = "Standard_D4ds_v5"
  client_cidrs                              = var.client_cidrs
  existing_vnet                             = var.existing_vnet
  link_vnet_to_blob_private_dns_zone        = var.link_vnet_to_blob_private_dns_zone
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
