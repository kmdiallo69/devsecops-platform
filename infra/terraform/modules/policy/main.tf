# Azure Policy — workload guardrails assigned at the resource-group scope,
# reported in the compliance dashboard, enforced INSIDE the cluster by the
# AKS policy add-on (a Gatekeeper managed by Azure).
#
# Built-ins are looked up by display name, not by GUID copied from a blog
# post: a wrong name fails the plan loudly.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.14"
    }
  }
}

data "azurerm_policy_set_definition" "pod_security_restricted" {
  display_name = "Kubernetes cluster pod security restricted standards for Linux-based workloads"
}

data "azurerm_policy_definition" "allowed_images" {
  display_name = "Kubernetes cluster containers should only use allowed images"
}

resource "azurerm_resource_group_policy_assignment" "pod_security_restricted" {
  name                 = "aks-pod-security-restricted"
  display_name         = "AKS: pod security restricted (${var.effect})"
  resource_group_id    = var.resource_group_id
  policy_definition_id = data.azurerm_policy_set_definition.pod_security_restricted.id

  parameters = jsonencode({
    effect             = { value = var.effect }
    excludedNamespaces = { value = var.excluded_namespaces }
  })
}

resource "azurerm_resource_group_policy_assignment" "allowed_images" {
  name                 = "aks-allowed-images"
  display_name         = "AKS: only signed images, by digest (${var.effect})"
  resource_group_id    = var.resource_group_id
  policy_definition_id = data.azurerm_policy_definition.allowed_images.id

  parameters = jsonencode({
    effect                      = { value = var.effect }
    allowedContainerImagesRegex = { value = var.allowed_image_regex }
    excludedNamespaces          = { value = var.excluded_namespaces }
  })
}
