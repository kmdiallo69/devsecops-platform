output "assignment_ids" {
  value = [
    azurerm_resource_group_policy_assignment.pod_security_restricted.id,
    azurerm_resource_group_policy_assignment.allowed_images.id,
  ]
}
