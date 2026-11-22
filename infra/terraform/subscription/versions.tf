terraform {
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }

  # Same state store as the environments, its own blob.
  backend "azurerm" {
    resource_group_name = "rg-llmgw-tfstate-frc"
    container_name      = "tfstate"
    key                 = "subscription.tfstate"
    use_azuread_auth    = true
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
  features {}
}
