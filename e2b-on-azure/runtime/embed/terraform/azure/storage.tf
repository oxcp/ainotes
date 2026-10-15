# The two shipped files reach the instance through a private container: custom
# data is capped at 64 KB and compose.yaml alone is most of that. The account
# refuses shared keys, so neither an account key nor a SAS exists to end up in
# the state file or on the instance; the identity reads these two blobs with a
# token and nothing else in the container.
resource "random_string" "storage" {
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  # A storage account name is 3 to 24 characters, lowercase letters and digits
  # only, and globally unique, so var.name loses everything else and is cut
  # short of the suffix that makes it unique.
  storage_account_name = "${substr(replace(var.name, "/[^a-z0-9]/", ""), 0, 16)}${random_string.storage.result}"
}

resource "azurerm_storage_account" "this" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access_enabled   = false
  tags                            = var.tags
}

locals {
  use_existing_blob_private_dns_zone = var.blob_private_dns_zone_id != null
  blob_private_dns_zone_id = local.use_existing_blob_private_dns_zone ? (
    var.blob_private_dns_zone_id
  ) : azurerm_private_dns_zone.blob[0].id
  blob_private_dns_zone_name                = split("/", local.blob_private_dns_zone_id)[8]
  blob_private_dns_zone_resource_group_name = split("/", local.blob_private_dns_zone_id)[4]
}

resource "azurerm_private_dns_zone" "blob" {
  count = local.use_existing_blob_private_dns_zone ? 0 : 1

  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "e2b" {
  name                  = "${var.vnet_name}-blob"
  resource_group_name   = local.blob_private_dns_zone_resource_group_name
  private_dns_zone_name = local.blob_private_dns_zone_name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "runner" {
  count = var.link_runner_vnet_to_blob_private_dns_zone ? 1 : 0

  name                  = "${var.runner_vnet_name}-blob"
  resource_group_name   = local.blob_private_dns_zone_resource_group_name
  private_dns_zone_name = local.blob_private_dns_zone_name
  virtual_network_id    = data.azurerm_virtual_network.runner.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "blob" {
  name                = "${var.name}-blob"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name}-blob"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [local.blob_private_dns_zone_id]
  }
}

resource "time_sleep" "private_network_propagation" {
  create_duration = "60s"

  triggers = {
    private_endpoint = azurerm_private_endpoint.blob.id
    e2b_dns_link     = azurerm_private_dns_zone_virtual_network_link.e2b.id
    runner_dns_link = var.link_runner_vnet_to_blob_private_dns_zone ? (
      azurerm_private_dns_zone_virtual_network_link.runner[0].id
    ) : "externally-managed"
    e2b_to_runner = azurerm_virtual_network_peering.e2b_to_runner.id
    runner_to_e2b = azurerm_virtual_network_peering.runner_to_e2b.id
  }
}

resource "azurerm_storage_container" "this" {
  name                  = "compose"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Not templatefile(): compose.yaml has its own ${...} interpolations. The
# content_md5 makes a changed file a changed blob on the next apply.
resource "azurerm_storage_blob" "compose_yaml" {
  name                 = "compose.yaml"
  storage_container_id = azurerm_storage_container.this.id
  type                 = "Block"
  source               = "${path.module}/../../compose/compose.yaml"
  content_md5          = filemd5("${path.module}/../../compose/compose.yaml")

  # Writing a blob is a data-plane call, authorized by the role assignment in
  # iam.tf rather than by a key (iam.tf says what the wait is for).
  depends_on = [
    time_sleep.rbac_propagation,
    time_sleep.private_network_propagation,
  ]
}

resource "azurerm_storage_blob" "dot_env" {
  name                 = ".env"
  storage_container_id = azurerm_storage_container.this.id
  type                 = "Block"
  source               = "${path.module}/../../compose/.env"
  content_md5          = filemd5("${path.module}/../../compose/.env")

  depends_on = [
    time_sleep.rbac_propagation,
    time_sleep.private_network_propagation,
  ]
}
