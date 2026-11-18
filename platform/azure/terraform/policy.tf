# Azure Policy — the same intent as the kind cluster's admission rules,
# expressed as Azure governance: assigned at the resource-group scope,
# reported in the compliance dashboard, enforced in-cluster by the AKS
# policy add-on (a Gatekeeper managed by Azure).
#
# Built-ins are looked up by display name, not by GUID copied from a blog
# post: a wrong name fails the plan loudly.

data "azurerm_policy_set_definition" "pod_security_restricted" {
  display_name = "Kubernetes cluster pod security restricted standards for Linux-based workloads"
}

data "azurerm_policy_definition" "allowed_images" {
  display_name = "Kubernetes cluster containers should only use allowed images"
}

resource "azurerm_resource_group_policy_assignment" "pod_security_restricted" {
  name                 = "aks-pod-security-restricted"
  display_name         = "AKS: pod security restricted (deny)"
  resource_group_id    = azurerm_resource_group.this.id
  policy_definition_id = data.azurerm_policy_set_definition.pod_security_restricted.id

  parameters = jsonencode({
    effect = { value = "deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "allowed_images" {
  name                 = "aks-allowed-images"
  display_name         = "AKS: only our signed images, by digest (deny)"
  resource_group_id    = azurerm_resource_group.this.id
  policy_definition_id = data.azurerm_policy_definition.allowed_images.id

  parameters = jsonencode({
    effect                      = { value = "deny" }
    allowedContainerImagesRegex = { value = var.allowed_image_regex }
  })
}
