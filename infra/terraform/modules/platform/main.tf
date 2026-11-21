# =============================================================================
# Platform — composition module
# =============================================================================
# Wires the building blocks into one environment. Environments
# (infra/terraform/environments/*) call ONLY this module, with their sizing:
# dev, staging and prod run the same code, differing by parameters alone —
# what is tested in dev is what runs in prod.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.14"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.9"
    }
  }
}

data "azurerm_client_config" "current" {}

# Globally-unique names (Key Vault, DNS prefix) without collisions between
# environments or with soft-deleted vaults from a previous deployment.
resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  # CAF-style naming: <type>-<workload>-<env>-<region>-<suffix>
  name = "${var.workload}-${var.environment}-${var.location_short}-${random_string.suffix.result}"

  administrators = distinct(concat([data.azurerm_client_config.current.object_id], var.extra_administrator_object_ids))

  tags = merge(var.tags, {
    workload    = var.workload
    environment = var.environment
    managed_by  = "terraform"
  })

  pod_cidr = "192.168.0.0/16"
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

module "monitoring" {
  source              = "../monitoring"
  name                = local.name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  retention_in_days   = var.log_retention_days
  daily_quota_gb      = var.log_daily_quota_gb
  tags                = local.tags
}

module "network" {
  source                = "../network"
  name                  = local.name
  resource_group_name   = azurerm_resource_group.this.name
  location              = var.location
  address_space         = var.address_space
  pod_cidr              = local.pod_cidr
  ingress_allowed_cidrs = var.ingress_allowed_cidrs
  tags                  = local.tags
}

module "key_vault" {
  source                     = "../key-vault"
  name                       = local.name
  resource_group_name        = azurerm_resource_group.this.name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = var.key_vault_sku
  administrator_object_ids   = local.administrators
  soft_delete_retention_days = var.key_vault_soft_delete_days
  private_endpoint_subnet_id = module.network.private_endpoints_subnet_id
  private_dns_zone_id        = module.network.key_vault_private_dns_zone_id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  tags                       = local.tags
}

module "aks" {
  source                     = "../aks"
  name                       = local.name
  resource_group_name        = azurerm_resource_group.this.name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  kubernetes_version         = var.kubernetes_version
  sku_tier                   = var.aks_sku_tier
  administrator_object_ids   = local.administrators
  nodes_subnet_id            = module.network.nodes_subnet_id
  pod_cidr                   = local.pod_cidr
  key_vault_id               = module.key_vault.id
  etcd_key_versionless_id    = module.key_vault.etcd_key_versionless_id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  system_pool                = var.system_pool
  user_pool                  = var.user_pool
  tags                       = local.tags
}

module "app_gateway" {
  source                     = "../app-gateway"
  name                       = local.name
  resource_group_name        = azurerm_resource_group.this.name
  location                   = var.location
  subnet_id                  = module.network.appgw_subnet_id
  key_vault_id               = module.key_vault.id
  backend_ip                 = module.network.ingress_ilb_ip
  tls_hostname               = var.tls_hostname
  waf_mode                   = var.waf_mode
  rate_limit_per_minute      = var.waf_rate_limit_per_minute
  autoscale                  = var.appgw_autoscale
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  tags                       = local.tags
}

module "policy" {
  source              = "../policy"
  resource_group_id   = azurerm_resource_group.this.id
  effect              = var.policy_effect
  allowed_image_regex = var.allowed_image_regex
}
