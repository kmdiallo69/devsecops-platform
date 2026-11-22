# staging — Production-like: zones, SLA tier, same WAF and policies — the last gate
# before prod. Not reachable from the Internet.
module "platform" {
  source = "../../modules/platform"

  environment    = "stg"
  location       = "francecentral"
  location_short = "frc"
  address_space  = "10.20.0.0/16" # distinct per environment (peering-ready)

  # WAF exposure: corporate ranges only (here: operator IP).
  ingress_allowed_cidrs = ["${var.admin_ip}/32"]

  kubernetes_version = "1.36"
  aks_sku_tier       = "Standard"
  # D4 system nodes: AKS add-ons fill a D2, leaving no room for the Defender sensor.
  system_pool = { vm_size = "Standard_D4ads_v7", node_count = 2, zones = ["1", "2", "3"] }
  user_pool   = { vm_size = "Standard_D4ads_v7", node_count = 2, zones = ["1", "2", "3"] }

  key_vault_sku              = "standard"
  key_vault_soft_delete_days = 30
  log_retention_days         = 30
  log_daily_quota_gb         = 5

  tls_hostname              = "llm-gateway.staging.internal"
  waf_mode                  = "Prevention"
  waf_rate_limit_per_minute = 60
  appgw_autoscale           = { min = 1, max = 3 }

  llm_api_key         = var.llm_api_key
  llm_api_key_version = var.llm_api_key_version

  tags = {
    cost_center = "platform"
    owner       = "devsecops"
  }
}
