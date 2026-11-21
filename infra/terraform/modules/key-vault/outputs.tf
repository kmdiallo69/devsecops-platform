# Handed out only after the administrators' RBAC has propagated: consumers
# (certificate, AKS KMS) can use the vault right away.
output "id" {
  value      = azurerm_key_vault.this.id
  depends_on = [time_sleep.rbac_propagation]
}

output "name" {
  value = azurerm_key_vault.this.name
}

output "etcd_key_versionless_id" {
  description = "Versionless: AKS KMS follows the automatic rotations."
  value       = azurerm_key_vault_key.etcd.versionless_id
}
