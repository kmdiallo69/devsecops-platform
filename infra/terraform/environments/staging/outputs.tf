output "resource_group" {
  value = module.platform.resource_group
}

output "aks_name" {
  value = module.platform.aks_name
}

output "key_vault_name" {
  value = module.platform.key_vault_name
}

output "waf_public_ip" {
  value = module.platform.waf_public_ip
}

output "egress_ip" {
  value = module.platform.egress_ip
}

output "ingress_ilb_ip" {
  value = module.platform.ingress_ilb_ip
}

output "appgw_cidr" {
  value = module.platform.appgw_cidr
}

output "kubectl" {
  value = module.platform.kubectl
}
