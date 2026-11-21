# prod — Zone-redundant everywhere, SLA tier, HSM-backed CMK, 90-day logs with no
# ingestion cap (a capped workspace silently drops security logs).
module "platform" {
  source = "../../modules/platform"

  environment    = "prd"
  location       = "francecentral"
  location_short = "frc"
  address_space  = "10.30.0.0/16" # distinct per environment (peering-ready)

  # WAF exposure: Internet: the WAF is the control in front of the app.
  ingress_allowed_cidrs = ["0.0.0.0/0"]

  kubernetes_version = "1.36"
  aks_sku_tier       = "Standard"
  system_pool        = { vm_size = "Standard_D4ads_v7", node_count = 3, zones = ["1", "2", "3"] }
  user_pool          = { vm_size = "Standard_D4ads_v7", node_count = 3, zones = ["1", "2", "3"] }

  key_vault_sku              = "premium"
  key_vault_soft_delete_days = 90
  log_retention_days         = 90
  log_daily_quota_gb         = -1

  tls_hostname              = "llm-gateway.example.com"
  waf_mode                  = "Prevention"
  waf_rate_limit_per_minute = 120
  appgw_autoscale           = { min = 2, max = 10 }

  llm_api_key         = var.llm_api_key
  llm_api_key_version = var.llm_api_key_version

  tags = {
    cost_center = "platform"
    owner       = "devsecops"
  }
}
