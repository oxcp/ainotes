# A dedicated virtual network with separate VM and private endpoint subnets.
resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  name                 = var.vm_subnet_name
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.vm_subnet_prefixes
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = var.private_endpoint_subnet_name
  resource_group_name               = azurerm_resource_group.this.name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = var.private_endpoint_subnet_prefixes
  private_endpoint_network_policies = "Disabled"
}

data "azurerm_virtual_network" "runner" {
  name                = var.runner_vnet_name
  resource_group_name = var.runner_vnet_resource_group_name
}

resource "azurerm_virtual_network_peering" "e2b_to_runner" {
  name                      = "${var.vnet_name}-to-${var.runner_vnet_name}"
  resource_group_name       = azurerm_resource_group.this.name
  virtual_network_name      = azurerm_virtual_network.this.name
  remote_virtual_network_id = data.azurerm_virtual_network.runner.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "runner_to_e2b" {
  name                      = "${var.runner_vnet_name}-to-${var.vnet_name}"
  resource_group_name       = var.runner_vnet_resource_group_name
  virtual_network_name      = var.runner_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.this.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
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
