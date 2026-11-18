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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # Local state, git-ignored: this is a short-lived test environment, created
  # and destroyed in one session. In a team, state goes to an Azure Storage
  # backend (encrypted, versioned, locked, private endpoint) — it holds
  # resource IDs and sometimes secrets, so it is a security asset itself.
}

provider "azurerm" {
  # Explicit subscription — never "whatever `az account` currently points
  # at": a CLI context switched to another subscription must not be where
  # resources land.
  subscription_id = var.subscription_id

  # Resource providers are registered once, explicitly (SETUP.md), not
  # silently by Terraform with broad permissions.
  resource_provider_registrations = "none"

  features {
    key_vault {
      # Never purge on destroy: purge protection is the point.
      purge_soft_delete_on_destroy = false
    }
  }
}
