output "storage_account_name" {
  value = azurerm_storage_account.state.name
}

output "init_command" {
  description = "Run inside infra/terraform/environments/<env>."
  value       = "terraform init -backend-config=\"storage_account_name=${azurerm_storage_account.state.name}\""
}
