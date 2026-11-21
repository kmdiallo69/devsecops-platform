# =============================================================================
# Bootstrap — the remote state store for every environment
# =============================================================================
# Terraform state holds every resource ID and sometimes secrets: it is a
# security asset. One storage account, one container, one blob per
# environment (dev.tfstate, staging.tfstate, prod.tfstate), locked during
# each apply (blob lease).
#
# Chicken-and-egg: this configuration's OWN state is local (git-ignored) —
# it is tiny, rarely changes, and can be re-imported if lost.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  # The account has no access keys: the container is created with Entra ID.
  storage_use_azuread = true
  features {}
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "state" {
  name     = "rg-llmgw-tfstate-frc"
  location = var.location
  tags = {
    workload   = "llmgw"
    purpose    = "terraform-state"
    managed_by = "terraform"
  }
}

resource "azurerm_storage_account" "state" {
  name                     = "stllmgwtfstate${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.state.name
  location                 = azurerm_resource_group.state.location
  account_tier             = "Standard"
  account_kind             = "StorageV2"
  account_replication_type = "GZRS" # zone-redundant + copy in the paired region

  # Identity-only access: no shared keys, no SAS, no anonymous blobs.
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  allow_nested_items_to_be_public  = false
  local_user_enabled               = false
  cross_tenant_replication_enabled = false

  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  infrastructure_encryption_enabled = true # double encryption at rest

  # Reachable from the operator's IP only. A CI runner would get its own
  # rule — or, in production, a private endpoint and self-hosted runners.
  #checkov:skip=CKV_AZURE_59:public endpoint restricted by network rules to the operator IP; private endpoint is the production design
  #checkov:skip=CKV2_AZURE_33:private endpoint = production design (needs a hub network / self-hosted runners)
  public_network_access = "Enabled"
  network_rules {
    default_action = "Deny"
    ip_rules       = [var.admin_ip]
    bypass         = ["AzureServices"]
  }

  # Every state version is kept: a corrupted or malicious apply can be
  # rolled back. Deleted blobs/containers are recoverable for 30 days.
  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  # Microsoft-managed keys + infrastructure encryption. A CMK for the state
  # account needs a vault that exists BEFORE any environment — a separate
  # "management" vault, the production next step.
  #checkov:skip=CKV2_AZURE_1:CMK on the state account needs a pre-existing management vault (production next step)
  #checkov:skip=CKV_AZURE_33:queue service not used (blob only)
  #checkov:skip=CKV2_AZURE_41:SAS disabled entirely (shared_access_key_enabled = false)

  tags = azurerm_resource_group.state.tags
}

resource "azurerm_storage_container" "tfstate" {
  # Read logging IS enabled — azurerm_monitor_diagnostic_setting.state_blob
  # below (StorageRead/Write/Delete). This check only recognises the legacy
  # azurerm_log_analytics_storage_insights mechanism.
  #checkov:skip=CKV2_AZURE_21:blob read logging implemented with a diagnostic setting (state_blob); the check only recognises legacy storage insights
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# The operator reads/writes state through Entra ID.
resource "azurerm_role_assignment" "operator_state" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# State cannot be deleted by accident (or by a compromised pipeline that
# only has Contributor): the lock must be removed explicitly first.
resource "azurerm_management_lock" "state" {
  count      = var.delete_lock ? 1 : 0
  name       = "do-not-delete-terraform-state"
  scope      = azurerm_storage_account.state.id
  lock_level = "CanNotDelete"
  notes      = "Holds the Terraform state of every environment."
}

# Who read or wrote the state, and when: every blob read/write/delete on the
# state account goes to a dedicated workspace (separate from the
# environments, so destroying an environment never erases this trail).
resource "azurerm_log_analytics_workspace" "state_audit" {
  name                         = "log-llmgw-tfstate-frc"
  location                     = azurerm_resource_group.state.location
  resource_group_name          = azurerm_resource_group.state.name
  sku                          = "PerGB2018"
  retention_in_days            = 90
  local_authentication_enabled = false
  tags                         = azurerm_resource_group.state.tags
}

resource "azurerm_monitor_diagnostic_setting" "state_blob" {
  name                       = "state-access-audit"
  target_resource_id         = "${azurerm_storage_account.state.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.state_audit.id

  enabled_log {
    category = "StorageRead"
  }
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}
