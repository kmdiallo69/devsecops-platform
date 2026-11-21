# Key Vault: the customer-managed key (CMK) that encrypts Kubernetes
# Secrets in etcd (AKS KMS), the WAF's TLS certificate, and the application
# secrets (Step 8).
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.14"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.13"
    }
  }
}

resource "azurerm_key_vault" "this" {
  name                = "kv-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = var.sku_name

  # Azure RBAC for data access (no legacy access policies): one permission
  # model for everything, auditable in one place.
  rbac_authorization_enabled = true

  # A deleted key cannot be destroyed during the retention period, even by
  # an admin: the protection against ransomware / malicious deletion of the
  # CMK (losing it = losing every secret it encrypts).
  purge_protection_enabled   = true
  soft_delete_retention_days = var.soft_delete_retention_days

  # Trade-off, stated plainly: in-VNet consumers (CSI driver, WAF) use the
  # PRIVATE ENDPOINT below. Public network access stays on because AKS KMS
  # with key_vault_network_access = "Public" is called from the AKS control
  # plane, which is not a "trusted Azure service" for the vault firewall.
  # Next step: KMS "Private" (requires API Server VNet Integration), then
  # public access off. Data access is gated by Entra ID + RBAC either way.
  #checkov:skip=CKV_AZURE_109:firewall incompatible with AKS KMS on a public vault (see comment)
  #checkov:skip=CKV_AZURE_189:public network access required by AKS KMS without API Server VNet Integration
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = var.tags
}

# Operators manage keys/certificates (data plane) — granted explicitly, not
# implied by owning the subscription.
resource "azurerm_role_assignment" "administrators" {
  for_each             = toset(var.administrator_object_ids)
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = each.value
}

# Azure RBAC takes a moment to propagate: creating a key right after the
# role assignment fails with 403 otherwise.
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.administrators]
  create_duration = "60s"
}

resource "time_static" "key_created" {}

resource "azurerm_key_vault_key" "etcd" {
  name         = "aks-etcd-kms"
  key_vault_id = azurerm_key_vault.this.id
  key_type     = var.sku_name == "premium" ? "RSA-HSM" : "RSA"
  key_size     = 2048
  key_opts     = ["encrypt", "decrypt", "wrapKey", "unwrapKey"]

  # standard SKU = software-protected key; premium = HSM-backed (the
  # production choice for a CMK, selected per environment).
  #checkov:skip=CKV_AZURE_112:HSM-backed when sku_name = premium (prod); software key in dev

  # Automatic rotation; AKS uses the VERSIONLESS key id, so it follows
  # rotations by itself.
  rotation_policy {
    automatic {
      time_after_creation = "P${var.key_rotation_days}D"
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

# Private endpoint: traffic from the VNet never leaves it, and resolves to a
# private IP through the privatelink DNS zone.
resource "azurerm_private_endpoint" "this" {
  name                = "pe-kv-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "kv"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

# Every key/secret read, write and permission denial.
resource "azurerm_monitor_diagnostic_setting" "this" {
  name                           = "kv-audit"
  target_resource_id             = azurerm_key_vault.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "audit"
  }
}
