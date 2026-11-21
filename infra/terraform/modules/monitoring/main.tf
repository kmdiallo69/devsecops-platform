# Central log store: AKS control-plane audit, Key Vault audit, WAF and
# access logs, container insights.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.14"
    }
  }
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_in_days
  # Hard cost ceiling (-1 = unlimited, the production setting: a capped
  # workspace silently stops collecting security logs).
  daily_quota_gb = var.daily_quota_gb
  # Agents authenticate with their managed identity, never a shared key.
  local_authentication_enabled = false
  tags                         = var.tags
}
