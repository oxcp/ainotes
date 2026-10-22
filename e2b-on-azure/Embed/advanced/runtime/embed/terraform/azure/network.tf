locals {
  use_existing_vnet        = var.existing_vnet != null
  vnet_id                  = local.use_existing_vnet ? data.azurerm_virtual_network.existing[0].id : azurerm_virtual_network.this[0].id
  vnet_name                = local.use_existing_vnet ? data.azurerm_virtual_network.existing[0].name : azurerm_virtual_network.this[0].name
  vnet_resource_group_name = local.use_existing_vnet ? var.existing_vnet.resource_group_name : azurerm_resource_group.this.name
}

data "azurerm_virtual_network" "existing" {
  count = local.use_existing_vnet ? 1 : 0

  name                = var.existing_vnet.name
  resource_group_name = var.existing_vnet.resource_group_name

  lifecycle {
    postcondition {
      condition     = lower(replace(self.location, " ", "")) == lower(replace(var.location, " ", ""))
      error_message = "The existing VNet must be in the deployment region."
    }
    postcondition {
      condition     = lower(self.resource_group_name) != lower(var.name)
      error_message = "Use a separate deployment resource group name so the existing VNet resource group remains externally managed."
    }
  }
}

resource "azurerm_virtual_network" "this" {
  count = local.use_existing_vnet ? 0 : 1

  name                = var.vnet_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  name                 = var.vm_subnet_name
  resource_group_name  = local.vnet_resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = var.vm_subnet_prefixes
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = var.private_endpoint_subnet_name
  resource_group_name               = local.vnet_resource_group_name
  virtual_network_name              = local.vnet_name
  address_prefixes                  = var.private_endpoint_subnet_prefixes
  private_endpoint_network_policies = "Disabled"
}

data "azurerm_virtual_network" "runner" {
  count = local.use_existing_vnet ? 0 : 1

  name                = var.runner_vnet_name
  resource_group_name = var.runner_vnet_resource_group_name

  lifecycle {
    precondition {
      condition     = var.runner_vnet_name != null && var.runner_vnet_resource_group_name != null
      error_message = "Set both runner_vnet_name and runner_vnet_resource_group_name when existing_vnet is null."
    }
  }
}

resource "azurerm_virtual_network_peering" "e2b_to_runner" {
  count = local.use_existing_vnet ? 0 : 1

  name                      = "${var.vnet_name}-to-${data.azurerm_virtual_network.runner[0].name}"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.this[0].name
  remote_virtual_network_id = data.azurerm_virtual_network.runner[0].id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "runner_to_e2b" {
  count = local.use_existing_vnet ? 0 : 1

  name                      = "${data.azurerm_virtual_network.runner[0].name}-to-${var.vnet_name}"
  resource_group_name       = data.azurerm_virtual_network.runner[0].resource_group_name
  virtual_network_name      = data.azurerm_virtual_network.runner[0].name
  remote_virtual_network_id = azurerm_virtual_network.this[0].id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

moved {
  from = azurerm_virtual_network.this
  to   = azurerm_virtual_network.this[0]
}

moved {
  from = azurerm_virtual_network_peering.e2b_to_runner
  to   = azurerm_virtual_network_peering.e2b_to_runner[0]
}

moved {
  from = azurerm_virtual_network_peering.runner_to_e2b
  to   = azurerm_virtual_network_peering.runner_to_e2b[0]
}

# The stable address: E2B_DASHBOARD_HOST and the three URL outputs name it
# before any instance exists, and each instance attaches it to its own
# network interface on first boot (a scale set cannot attach one). Standing
# on its own, it survives every replacement.
resource "azurerm_public_ip" "this" {
  name                = var.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# An instance of a Flexible scale set gets no outbound address of its own, and
# the address above only reaches its interface once the first boot has already
# downloaded Docker and called Resource Manager. The NAT gateway is what
# carries that first boot, and every later egress: the instance's downloads,
# the image pulls and whatever the sandboxes reach, which is anywhere.
resource "azurerm_public_ip" "nat" {
  name                = "${var.name}-nat"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                = var.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "this" {
  subnet_id      = azurerm_subnet.this.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}
