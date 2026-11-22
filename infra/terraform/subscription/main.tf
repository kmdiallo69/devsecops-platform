# =============================================================================
# Subscription baseline — Microsoft Defender for Cloud
# =============================================================================
# Subscription-wide, not per environment: what a platform team applies to
# every subscription it vends. Applied ONCE, before any environment; every
# AKS cluster and Key Vault created afterwards is covered automatically.
#
#   Plan                 Covers
#   -------------------  ------------------------------------------------------
#   CloudPosture (CSPM)  misconfigurations, attack paths across resources,
#                        agentless K8s discovery, registry image scanning
#   Containers           runtime threat detection on AKS (Defender sensor),
#                        K8s control-plane audit analytics, image vulnerability
#                        assessment
#   KeyVaults            anomalous access to vaults (e.g. secret enumeration)
#
# Each paid plan has a 30-day free trial per subscription; `enable_defender =
# false` returns every plan to Free with one apply.

locals {
  tier = var.enable_defender ? "Standard" : "Free"
}

resource "azurerm_security_center_subscription_pricing" "cspm" {
  resource_type = "CloudPosture"
  tier          = local.tier

  dynamic "extension" {
    for_each = var.enable_defender ? toset([
      "AgentlessDiscoveryForKubernetes",
      "ContainerRegistriesVulnerabilityAssessments",
    ]) : toset([])
    content {
      name = extension.value
    }
  }
}

resource "azurerm_security_center_subscription_pricing" "containers" {
  resource_type = "Containers"
  tier          = local.tier

  dynamic "extension" {
    for_each = var.enable_defender ? toset([
      "ContainerSensor",                             # runtime threat detection on the nodes
      "AgentlessDiscoveryForKubernetes",             # inventory + attack paths without an agent
      "ContainerRegistriesVulnerabilityAssessments", # CVEs in images
    ]) : toset([])
    content {
      name = extension.value
    }
  }
}

resource "azurerm_security_center_subscription_pricing" "key_vaults" {
  resource_type = "KeyVaults"
  tier          = local.tier
}

# Who gets the high-severity alerts — the address lives in the git-ignored
# terraform.tfvars, never in the repository.
resource "azurerm_security_center_contact" "this" {
  #checkov:skip=CKV_AZURE_20:a phone number is personal data — alerts are routed by email (and, in production, to the on-call tool via the alert's action group), never a number committed to Git
  name                = "default"
  email               = var.security_contact_email
  alert_notifications = true
  alerts_to_admins    = true
}
