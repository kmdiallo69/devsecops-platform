output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "aks_name" {
  value = module.aks.name
}

output "key_vault_name" {
  value = module.key_vault.name
}

output "oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "waf_public_ip" {
  value = module.app_gateway.public_ip
}

output "egress_ip" {
  value = module.network.egress_ip
}

output "ingress_ilb_ip" {
  description = "Must match the environment's Kustomize overlay (deploy/k8s/overlays/<env>)."
  value       = module.network.ingress_ilb_ip
}

output "appgw_cidr" {
  description = "Must match the environment's Kustomize overlay NetworkPolicy."
  value       = module.network.appgw_cidr
}

output "kubectl" {
  description = "Private cluster: kubectl through Azure Resource Manager (Entra ID + Azure RBAC)."
  value       = "az aks command invoke -g ${azurerm_resource_group.this.name} -n ${module.aks.name} --command"
}
