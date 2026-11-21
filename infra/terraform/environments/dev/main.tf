# dev — Smallest footprint that still runs the FULL design (private cluster, WAF,
# NAT, CMK). Fits a 4-vCPU quota: 1 system + 1 user node.
module "platform" {
  source = "../../modules/platform"

  environment    = "dev"
  location       = "francecentral"
  location_short = "frc"
  address_space  = "10.10.0.0/16" # distinct per environment (peering-ready)

  # WAF exposure: operator IP only.
  ingress_allowed_cidrs = ["${var.admin_ip}/32"]

  kubernetes_version = "1.36"
  aks_sku_tier       = "Free"
  system_pool        = { vm_size = "Standard_D2ads_v7", node_count = 1 }
  user_pool          = { vm_size = "Standard_D2ads_v7", node_count = 1 }

  key_vault_sku              = "standard"
  key_vault_soft_delete_days = 7
  log_retention_days         = 30
  log_daily_quota_gb         = 0.5

  tls_hostname              = "llm-gateway.dev.internal"
  waf_mode                  = "Prevention"
  waf_rate_limit_per_minute = 60
  appgw_autoscale           = { min = 0, max = 2 }

  llm_api_key         = var.llm_api_key
  llm_api_key_version = var.llm_api_key_version

  tags = {
    cost_center = "platform"
    owner       = "devsecops"
  }
}
