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
  location                         = "westus2"
  zone                             = "1"
  instance_size                    = "Standard_D4s_v6"
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
