output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "oidc_issuer_url" {
  description = "Workload Identity federation issuer (Step 8)."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubectl" {
  description = "Private cluster: run kubectl through Azure Resource Manager (Entra ID + Azure RBAC, no network path)."
  value       = "az aks command invoke -g ${azurerm_resource_group.this.name} -n ${azurerm_kubernetes_cluster.this.name} --command"
}

output "waf_public_ip" {
  value = azurerm_public_ip.appgw.ip_address
}

output "egress_ip" {
  description = "The single public IP all cluster egress uses (NAT Gateway)."
  value       = azurerm_public_ip.nat.ip_address
}

output "ingress_ilb_ip" {
  description = "Static IP the app's internal LoadBalancer Service must use."
  value       = local.ingress_ilb_ip
}
