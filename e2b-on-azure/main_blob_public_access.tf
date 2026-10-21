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
  location      = "southeastasia"
  zone          = "1"
  instance_size = "Standard_D4ds_v5"
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
