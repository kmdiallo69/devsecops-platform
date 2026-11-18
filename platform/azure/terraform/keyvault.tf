# Key Vault: the customer-managed key (CMK) that encrypts Kubernetes
# Secrets in etcd (AKS KMS), and — Step 8 — the application secrets.
resource "azurerm_key_vault" "this" {
  name                = "kv-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Azure RBAC for data access (no legacy access policies): one
  # permission model for everything, auditable in one place.
  rbac_authorization_enabled = true

  # A deleted key cannot be destroyed for 7 days, even by an admin: the
  # protection against ransomware / malicious deletion of the CMK (losing
  # the key = losing every secret it encrypts).
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  # Trade-off, stated plainly: in-VNet consumers (the CSI driver on the
  # nodes) use the PRIVATE ENDPOINT below. Public network access stays on
  # because AKS KMS with key_vault_network_access = "Public" is called from
  # the AKS control plane, which is not a "trusted Azure service" for the
  # vault firewall. Next step: KMS "Private" (requires API Server VNet
  # Integration), then public access off. Data access is gated by Entra ID
  # + RBAC either way.
  #checkov:skip=CKV_AZURE_109:firewall incompatible with AKS KMS on a public vault; production = private endpoint
  #checkov:skip=CKV_AZURE_189:same — public network access required by AKS KMS without private link
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = local.tags
}

# The operator manages keys (data plane) — granted explicitly, not implied
# by owning the subscription.
resource "azurerm_role_assignment" "operator_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# AKS uses the key to wrap/unwrap etcd encryption keys — nothing else.
resource "azurerm_role_assignment" "aks_kms" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# ...and AKS validates the vault through Azure Resource Manager before
# enabling KMS (`Microsoft.KeyVault/vaults/read`): a CONTROL-plane read the
# data-plane role above does not include. Reader on this vault only.
# Found when cluster creation failed with AuthorizationFailed.
resource "azurerm_role_assignment" "aks_kv_reader" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "time_sleep" "aks_rbac_propagation" {
  depends_on      = [azurerm_role_assignment.aks_kv_reader]
  create_duration = "90s"
}

# Azure RBAC takes a moment to propagate: creating the key right after the
# role assignment fails with 403 otherwise.
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.operator_kv_admin, azurerm_role_assignment.aks_kms, azurerm_role_assignment.appgw_kv_secrets]
  create_duration = "60s"
}

resource "time_static" "key_created" {}

resource "azurerm_key_vault_key" "etcd" {
  name         = "aks-etcd-kms"
  key_vault_id = azurerm_key_vault.this.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["encrypt", "decrypt", "wrapKey", "unwrapKey"]

  # Standard vault = software-protected key. HSM-backed keys need the
  # premium SKU (or Managed HSM): the production choice for a CMK.
  #checkov:skip=CKV_AZURE_112:HSM-backed key needs premium SKU; software key for this test

  # Automatic rotation every 90 days; each version expires after a year.
  # AKS uses the VERSIONLESS key id, so it follows rotations by itself.
  rotation_policy {
    automatic {
      time_after_creation = "P90D"
    }
    expire_after         = "P365D"
    notify_before_expiry = "P30D"
  }
  expiration_date = timeadd(time_static.key_created.rfc3339, "8760h")

  lifecycle {
    ignore_changes = [expiration_date] # rotations set the date on new versions
  }

  depends_on = [time_sleep.rbac_propagation]
}

resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                           = "kv-audit"
  target_resource_id             = azurerm_key_vault.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  # Every key/secret read, write and permission denial.
  enabled_log {
    category_group = "audit"
  }
}

# Private endpoint: traffic from the VNet to the vault never leaves it, and
# resolves to a private IP through the privatelink DNS zone.
resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "kv"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}
