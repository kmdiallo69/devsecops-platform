# =============================================================================
# Inbound — Application Gateway WAF_v2 in front of the app
# =============================================================================
# TLS terminates here (certificate from Key Vault, TLS 1.2+ only), every
# request is inspected by the WAF (OWASP-based rules + bot protection +
# per-client rate limit), then forwarded to the app's INTERNAL load balancer.
#
# Design choice: static backend (the ILB IP), not AGIC. AGIC is an in-cluster
# controller with Contributor rights on the gateway, rewriting its config at
# runtime — drift with Terraform, and a high-value identity inside the
# cluster. Here the gateway is 100% Terraform; the cluster cannot write to it.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.14"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.13"
    }
  }
}

resource "azurerm_user_assigned_identity" "this" {
  name                = "id-agw-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# The gateway reads its TLS certificate from Key Vault — read-only.
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# RBAC propagation before the gateway first fetches the certificate
# (otherwise provisioning can fail on a 403 from Key Vault).
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.kv_secrets_user]
  create_duration = "90s"
}

# TLS certificate, generated and auto-renewed by Key Vault. Self-signed
# without a public domain; with one: a CA-issued certificate (Key
# Vault-integrated CA or imported) — same wiring.
resource "azurerm_key_vault_certificate" "tls" {
  name         = "ingress-tls"
  key_vault_id = var.key_vault_id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }
    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = false
    }
    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }
    secret_properties {
      content_type = "application/x-pkcs12"
    }
    x509_certificate_properties {
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"] # server authentication
      key_usage          = ["digitalSignature", "keyEncipherment"]
      subject            = "CN=${var.tls_hostname}"
      validity_in_months = 3
      subject_alternative_names {
        dns_names = [var.tls_hostname]
      }
    }
  }
}

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "waf-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  policy_settings {
    enabled = true
    # Prevention = block. Detection only logs: a first tuning period on a
    # new app, never the end state.
    mode                        = var.waf_mode
    request_body_check          = true
    request_body_enforcement    = true
    max_request_body_size_in_kb = 128 # the gateway accepts ≤20 messages × 4000 chars
    file_upload_limit_in_mb     = 1   # no file uploads in this API

    # Never store credentials in WAF logs (an LLM API key in a header would
    # otherwise land in Log Analytics in clear text).
    log_scrubbing {
      enabled = true
      rule {
        match_variable          = "RequestHeaderNames"
        selector_match_operator = "Equals"
        selector                = "Authorization"
      }
    }
  }

  # Per-client rate limit: one IP flooding the LLM endpoint is cut off at
  # the edge, before it costs a single token (OWASP LLM10). Approximate by
  # design (sliding window, several instances).
  custom_rules {
    name                 = "ratelimitperclient"
    priority             = 10
    rule_type            = "RateLimitRule"
    action               = "Block"
    rate_limit_duration  = "OneMin"
    rate_limit_threshold = var.rate_limit_per_minute
    group_rate_limit_by  = "ClientAddr"

    match_conditions {
      match_variables {
        variable_name = "RequestUri"
      }
      operator     = "BeginsWith"
      match_values = ["/"]
    }
  }

  managed_rules {
    #checkov:skip=CKV_AZURE_135:Checkov only recognises the legacy OWASP 3.x types; DRS 2.1 is built on CRS 3.3.2, which includes rule 944240 (Log4Shell)
    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }
    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.1"
    }
  }
}

resource "azurerm_public_ip" "this" {
  name                = "pip-agw-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
  tags                = var.tags
}

locals {
  agw = {
    frontend_ip   = "public"
    frontend_port = "https"
    listener      = "https"
    backend_pool  = "app-ilb"
    backend_http  = "app-http"
    probe         = "app-healthz"
    cert          = "ingress-tls"
  }
}

resource "azurerm_application_gateway" "this" {
  name                = "agw-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  zones               = var.zones
  firewall_policy_id  = azurerm_web_application_firewall_policy.this.id
  http2_enabled       = true
  tags                = var.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = var.autoscale.min
    max_capacity = var.autoscale.max
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  # TLS 1.2+ with strong ciphers only.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S"
  }

  gateway_ip_configuration {
    name      = "gateway"
    subnet_id = var.subnet_id
  }

  frontend_ip_configuration {
    name                 = local.agw.frontend_ip
    public_ip_address_id = azurerm_public_ip.this.id
  }

  frontend_port {
    name = local.agw.frontend_port
    port = 443
  }

  ssl_certificate {
    name                = local.agw.cert
    key_vault_secret_id = azurerm_key_vault_certificate.tls.versionless_secret_id # follows auto-renewal
  }

  http_listener {
    name                           = local.agw.listener
    frontend_ip_configuration_name = local.agw.frontend_ip
    frontend_port_name             = local.agw.frontend_port
    protocol                       = "Https"
    ssl_certificate_name           = local.agw.cert
  }

  backend_address_pool {
    name         = local.agw.backend_pool
    ip_addresses = [var.backend_ip]
  }

  probe {
    name                = local.agw.probe
    protocol            = "Http"
    host                = var.backend_ip
    path                = var.health_probe_path
    interval            = 15
    timeout             = 5
    unhealthy_threshold = 3
    match {
      status_code = ["200"]
    }
  }

  # Hop to the ILB is HTTP inside the VNet; strict end-to-end TLS = HTTPS
  # backend + certificate on the app.
  backend_http_settings {
    name                  = local.agw.backend_http
    port                  = 80
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    request_timeout       = 60 # LLM responses can take a while
    probe_name            = local.agw.probe
  }

  request_routing_rule {
    name                       = "app"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = local.agw.listener
    backend_address_pool_name  = local.agw.backend_pool
    backend_http_settings_name = local.agw.backend_http
  }

  depends_on = [time_sleep.rbac_propagation]
}

# Access log + WAF log (every blocked request, with the rule that fired).
resource "azurerm_monitor_diagnostic_setting" "this" {
  name                           = "agw-logs"
  target_resource_id             = azurerm_application_gateway.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }
}
