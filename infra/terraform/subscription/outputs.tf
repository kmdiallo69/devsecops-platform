output "defender_plans" {
  value = {
    cloud_posture = azurerm_security_center_subscription_pricing.cspm.tier
    containers    = azurerm_security_center_subscription_pricing.containers.tier
    key_vaults    = azurerm_security_center_subscription_pricing.key_vaults.tier
  }
}
