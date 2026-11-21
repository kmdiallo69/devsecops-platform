provider "azurerm" {
  # Explicit subscription — never "whatever `az account` currently points
  # at": a CLI context switched elsewhere must not be where resources land.
  subscription_id = var.subscription_id

  # Resource providers are registered once, explicitly, not silently by
  # Terraform with broad permissions.
  resource_provider_registrations = "none"

  # Data-plane calls (state, Key Vault) with Entra ID, never shared keys.
  storage_use_azuread = true

  features {
    key_vault {
      # Purge protection is the point: never purge on destroy.
      purge_soft_delete_on_destroy = false
    }
  }
}
