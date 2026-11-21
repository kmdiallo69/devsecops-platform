# =============================================================================
# App identity — Workload Identity + one Key Vault secret, least privilege
# =============================================================================
#
#   pod (ServiceAccount llm-gateway/llm-gateway)
#     └─ Secrets Store CSI driver exchanges the SA token (OIDC, no secret)
#          └─ Entra ID: federated credential -> this managed identity
#               └─ Key Vault Secrets User on ONE secret (not the vault)
#                    └─ secret mounted as a file (tmpfs, read-only)
#
# No client secret anywhere, no Kubernetes Secret, no env var. The app
# container itself never receives an Azure credential: only the CSI driver
# uses the federated token, at mount time.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.14"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7" # ephemeral resources
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.13"
    }
  }
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.app_name}-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Trust exactly ONE Kubernetes ServiceAccount of THIS cluster: a token from
# another namespace, another SA or another cluster is refused by Entra ID.
resource "azurerm_federated_identity_credential" "app" {
  name                      = "${var.namespace}-${var.service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.app.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.namespace}:${var.service_account}"
}

# Initial value when no real key is supplied: random, EPHEMERAL — never
# written to the plan or the state.
ephemeral "random_password" "placeholder" {
  length  = 48
  special = false
}

resource "time_static" "secret_created" {}

resource "azurerm_key_vault_secret" "this" {
  name         = var.secret_name
  key_vault_id = var.key_vault_id
  content_type = "text/plain"

  # WRITE-ONLY: the value goes to Key Vault and nowhere else — not in the
  # plan, not in the state (which every Terraform operator can read).
  # Rotate: set a new value and bump value_wo_version.
  value_wo         = var.secret_value != null ? var.secret_value : ephemeral.random_password.placeholder.result
  value_wo_version = var.secret_version

  # Forces rotation: an expired secret fails loudly instead of living forever.
  expiration_date = timeadd(time_static.secret_created.rfc3339, "${var.secret_max_age_days * 24}h")

  lifecycle {
    ignore_changes = [expiration_date]
  }

  tags = var.tags
}

# Read access to THIS secret only — not to the vault, not to the etcd key,
# not to the TLS certificate.
resource "azurerm_role_assignment" "secret_reader" {
  scope                = azurerm_key_vault_secret.this.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}
