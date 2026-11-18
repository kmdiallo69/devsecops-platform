data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name = "devsecops-${random_string.suffix.result}"
  tags = {
    project    = "devsecops-platform"
    managed_by = "terraform"
    # Ephemeral by design: created for a test, destroyed right after.
    lifecycle = "ephemeral"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

# Central log store: AKS control-plane audit logs, Key Vault audit logs,
# container insights. Daily cap = hard cost ceiling for a test environment.
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.5
  # Agents authenticate with their managed identity, never a shared key.
  local_authentication_enabled = false
  tags                         = local.tags
}

# The cluster's own identity (control plane). User-assigned, so its Key
# Vault permission (KMS) exists BEFORE the cluster is created.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-aks-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}
