mock_provider "azurerm" {
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed"
    }
  }

  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed/providers/Microsoft.Network/virtualNetworks/e2bvnet"
    }
  }

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed/providers/Microsoft.Network/networkSecurityGroups/e2b"
    }
  }

  mock_resource "azurerm_nat_gateway" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed/providers/Microsoft.Network/natGateways/e2b"
    }
  }

  mock_resource "azurerm_public_ip" {
    defaults = {
      id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed/providers/Microsoft.Network/publicIPAddresses/e2b"
      ip_address = "198.51.100.10"
    }
  }

  mock_resource "azurerm_storage_account" {
    defaults = {
      id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed/providers/Microsoft.Storage/storageAccounts/e2bstorage"
      primary_blob_host = "e2bstorage.blob.core.windows.net"
    }
  }

  mock_resource "azurerm_storage_container" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed/providers/Microsoft.Storage/storageAccounts/e2bstorage/blobServices/default/containers/compose"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed/providers/Microsoft.ManagedIdentity/userAssignedIdentities/e2b"
      client_id    = "22222222-2222-2222-2222-222222222222"
      principal_id = "33333333-3333-3333-3333-333333333333"
    }
  }

  mock_resource "azurerm_role_definition" {
    defaults = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/44444444-4444-4444-4444-444444444444"
    }
  }

  mock_data "azurerm_virtual_network" {
    defaults = {
      id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared-network/providers/Microsoft.Network/virtualNetworks/shared-vnet"
      name                = "shared-vnet"
      resource_group_name = "shared-network"
      location            = "eastasia"
    }
  }

  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
      object_id       = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/e2b-embed/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result = "Mock-Only-Password-1234!"
    }
  }
}
mock_provider "time" {}

override_resource {
  target = azurerm_subnet.this
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared-network/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/e2b-vm"
  }
}

override_resource {
  target = azurerm_subnet.private_endpoints
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared-network/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/e2b-private-endpoints"
  }
}

variables {
  location     = "eastasia"
  client_cidrs = ["198.51.100.7/32"]
  existing_vnet = {
    name                = "shared-vnet"
    resource_group_name = "shared-network"
  }
  vm_subnet_name                   = "e2b-vm"
  vm_subnet_prefixes               = ["10.10.0.0/25"]
  private_endpoint_subnet_name     = "e2b-private-endpoints"
  private_endpoint_subnet_prefixes = ["10.10.0.128/26"]
}

run "existing_vnet_new_zone" {
  command = apply

  assert {
    condition = (
      length(azurerm_virtual_network.this) == 0 &&
      length(azurerm_virtual_network_peering.e2b_to_runner) == 0 &&
      length(azurerm_virtual_network_peering.runner_to_e2b) == 0 &&
      length(data.azurerm_virtual_network.runner) == 0
    )
    error_message = "Existing-VNet mode must not create a VNet, either peering, or read a separate runner VNet."
  }

  assert {
    condition = (
      azurerm_subnet.this.virtual_network_name == "shared-vnet" &&
      azurerm_subnet.private_endpoints.virtual_network_name == "shared-vnet" &&
      azurerm_subnet.this.resource_group_name == "shared-network" &&
      azurerm_subnet.private_endpoints.resource_group_name == "shared-network" &&
      azurerm_subnet.this.name == "e2b-vm" &&
      azurerm_subnet.private_endpoints.name == "e2b-private-endpoints" &&
      azurerm_subnet.this.address_prefixes == tolist(["10.10.0.0/25"]) &&
      azurerm_subnet.private_endpoints.address_prefixes == tolist(["10.10.0.128/26"])
    )
    error_message = "Both new subnets must use the supplied VNet, resource group, names and CIDRs."
  }

  assert {
    condition = (
      one(azurerm_orchestrated_virtual_machine_scale_set.this.network_interface).ip_configuration[0].subnet_id == azurerm_subnet.this.id &&
      azurerm_private_endpoint.blob.subnet_id == azurerm_subnet.private_endpoints.id &&
      azurerm_subnet_nat_gateway_association.this.subnet_id == azurerm_subnet.this.id &&
      azurerm_subnet_network_security_group_association.this.subnet_id == azurerm_subnet.this.id
    )
    error_message = "VMSS, endpoint, NAT and NSG must attach to the correct new subnets."
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.blob) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.e2b) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.runner) == 0 &&
      azurerm_private_dns_zone_virtual_network_link.e2b[0].virtual_network_id == output.vnet_id &&
      one(azurerm_private_endpoint.blob.private_dns_zone_group).private_dns_zone_ids == tolist([azurerm_private_dns_zone.blob[0].id])
    )
    error_message = "Case A must create one zone, one VNet link and the endpoint's zone group."
  }

  assert {
    condition = (
      !azurerm_storage_account.this.public_network_access_enabled &&
      !azurerm_storage_account.this.shared_access_key_enabled &&
      one(azurerm_private_endpoint.blob.private_service_connection).private_connection_resource_id == azurerm_storage_account.this.id &&
      one(azurerm_private_endpoint.blob.private_service_connection).subresource_names == tolist(["blob"])
    )
    error_message = "The endpoint must target the new account's Blob service with public/shared-key access disabled."
  }

  assert {
    condition = (
      length(azurerm_role_assignment.existing_subnet_join) == 1 &&
      azurerm_role_assignment.existing_subnet_join[0].scope == azurerm_subnet.this.id &&
      azurerm_role_assignment.existing_subnet_join[0].principal_id == azurerm_user_assigned_identity.this.principal_id &&
      contains(azurerm_role_definition.public_ip_attach.assignable_scopes, "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared-network") &&
      time_sleep.rbac_propagation.triggers.existing_subnet_join == azurerm_role_assignment.existing_subnet_join[0].id
    )
    error_message = "VM bootstrap must wait for subnet-scoped join permission outside the deployment resource group."
  }
}

run "existing_zone_existing_link" {
  command = apply

  variables {
    blob_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.blob) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.e2b) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.runner) == 0 &&
      one(azurerm_private_endpoint.blob.private_dns_zone_group).private_dns_zone_ids == tolist([var.blob_private_dns_zone_id]) &&
      time_sleep.private_network_propagation.triggers.e2b_dns_link == "externally-managed"
    )
    error_message = "Case B must reuse the zone/link while maintaining the new endpoint's DNS zone group."
  }
}

run "dedicated_vnet_existing_zone" {
  command = apply

  variables {
    existing_vnet                             = null
    runner_vnet_name                          = "shared-vnet"
    runner_vnet_resource_group_name           = "shared-network"
    link_runner_vnet_to_blob_private_dns_zone = false
    blob_private_dns_zone_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/shared-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.blob) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.e2b) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.runner) == 0 &&
      azurerm_private_dns_zone_virtual_network_link.e2b[0].resource_group_name == "shared-dns" &&
      azurerm_private_dns_zone_virtual_network_link.e2b[0].private_dns_zone_name == "privatelink.blob.core.windows.net" &&
      azurerm_private_dns_zone_virtual_network_link.e2b[0].virtual_network_id == output.vnet_id
    )
    error_message = "A newly created dedicated VNet must get a link even when reusing a DNS zone and the runner's existing link."
  }
}

run "dedicated_vnet_compatibility" {
  command = apply

  variables {
    existing_vnet                   = null
    runner_vnet_name                = "shared-vnet"
    runner_vnet_resource_group_name = "shared-network"
  }

  assert {
    condition = (
      length(azurerm_virtual_network.this) == 1 &&
      length(azurerm_virtual_network_peering.e2b_to_runner) == 1 &&
      length(azurerm_virtual_network_peering.runner_to_e2b) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.e2b) == 1 &&
      length(azurerm_private_dns_zone_virtual_network_link.runner) == 1 &&
      length(azurerm_role_assignment.existing_subnet_join) == 0 &&
      azurerm_subnet.this.resource_group_name == azurerm_resource_group.this.name &&
      output.vnet_id == azurerm_virtual_network.this[0].id
    )
    error_message = "The default dedicated-VNet topology and its two DNS links must be preserved."
  }
}

run "reject_wrong_vnet_region" {
  command = plan

  variables {
    location = "eastus"
  }

  expect_failures = [data.azurerm_virtual_network.existing]
}

run "reject_shared_deployment_group" {
  command = plan

  variables {
    name = "shared-network"
  }

  expect_failures = [data.azurerm_virtual_network.existing]
}

run "reject_missing_runner_in_dedicated_mode" {
  command = plan

  variables {
    existing_vnet = null
  }

  expect_failures = [data.azurerm_virtual_network.runner]
}
