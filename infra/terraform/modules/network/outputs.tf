# Subnet IDs are only handed out once their NSG (and NAT Gateway) is
# attached: nothing can be deployed into an unprotected subnet, even for
# the few seconds Azure would otherwise allow.

output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "nodes_subnet_id" {
  value = azurerm_subnet.nodes.id
  depends_on = [
    azurerm_subnet_network_security_group_association.nodes,
    azurerm_subnet_nat_gateway_association.nodes,
  ]
}

output "appgw_subnet_id" {
  value      = azurerm_subnet.appgw.id
  depends_on = [azurerm_subnet_network_security_group_association.appgw]
}

output "private_endpoints_subnet_id" {
  value      = azurerm_subnet.private_endpoints.id
  depends_on = [azurerm_subnet_network_security_group_association.private_endpoints]
}

output "key_vault_private_dns_zone_id" {
  value      = azurerm_private_dns_zone.key_vault.id
  depends_on = [azurerm_private_dns_zone_virtual_network_link.key_vault]
}

output "ingress_ilb_ip" {
  description = "Static IP the app's internal LoadBalancer Service must use."
  value       = local.ingress_ilb_ip
}

output "appgw_cidr" {
  description = "The only source allowed into the app pods (NetworkPolicy)."
  value       = local.appgw_cidr
}

output "egress_ip" {
  description = "The single public IP all cluster egress uses."
  value       = azurerm_public_ip.nat.ip_address
}
