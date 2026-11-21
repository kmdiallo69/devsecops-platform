terraform {
  required_version = ">= 1.11" # write-only attributes, ephemeral variables

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

  # Remote state, one file per environment: an apply in prod can never touch
  # another environment's state. Storage account (infra/terraform/bootstrap)
  # passed at init — see infra/terraform/README.md. Entra ID auth only: the
  # account has no access keys.
  backend "azurerm" {
    resource_group_name = "rg-llmgw-tfstate-frc"
    container_name      = "tfstate"
    key                 = "prod.tfstate"
    use_azuread_auth    = true
  }
}
