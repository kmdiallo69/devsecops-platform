output "client_id" {
  description = "Goes into the ServiceAccount annotation and the SecretProviderClass."
  value       = azurerm_user_assigned_identity.app.client_id
}

output "secret_name" {
  value = azurerm_key_vault_secret.this.name
}
