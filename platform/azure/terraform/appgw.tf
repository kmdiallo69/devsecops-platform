# =============================================================================
# Inbound — Application Gateway WAF_v2 in front of the app
# =============================================================================
# TLS terminates here (certificate from Key Vault, TLS 1.2+ only), every
# request is inspected by the WAF (OWASP-based rules + bot protection +
# per-client rate limit), then forwarded to the app's INTERNAL load balancer.
#
# Design choice: static backend (the ILB IP), not AGIC. AGIC is an in-cluster
# controller with Contributor rights on the gateway, rewriting its config at
# runtime — drift with Terraform and a high-value identity inside the
# cluster. Here the gateway is 100% Terraform, and the cluster has no write
# access to it.

resource "azurerm_user_assigned_identity" "appgw" {
  name                = "id-appgw-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# The gateway reads its TLS certificate from Key Vault — read-only.
resource "azurerm_role_assignment" "appgw_kv_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw.principal_id
}

# RBAC propagation before the gateway first fetches the certificate
# (otherwise provisioning can fail on a 403 from Key Vault).
resource "time_sleep" "appgw_rbac_propagation" {
  depends_on      = [azurerm_role_assignment.appgw_kv_secrets]
  create_duration = "90s"
}

# TLS certificate, generated and auto-renewed by Key Vault. Self-signed for
# this test (no public domain); production: a CA-issued certificate
# (Key Vault-integrated CA or imported), same wiring.
resource "azurerm_key_vault_certificate" "ingress" {
  name         = "llm-gateway-tls"
  key_vault_id = azurerm_key_vault.this.id

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
      subject            = "CN=llm-gateway.devsecops.internal"
      validity_in_months = 3
      subject_alternative_names {
        dns_names = ["llm-gateway.devsecops.internal"]
      }
    }
  }

  depends_on = [time_sleep.rbac_propagation]
}

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "waf-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  policy_settings {
    enabled = true
    # Prevention = block. (Detection only logs: the mode for a first tuning
    # period on a real app, never the end state.)
    mode                        = "Prevention"
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
  # the edge, before it costs a single token (OWASP LLM10).
  custom_rules {
    name                 = "ratelimitperclient"
    priority             = 10
    rule_type            = "RateLimitRule"
    action               = "Block"
    rate_limit_duration  = "OneMin"
    rate_limit_threshold = 60
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
    # Microsoft's OWASP-CRS-based ruleset: SQLi, XSS, RCE, LFI, protocol
    # violations...
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

resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags
}

locals {
  agw = {
    frontend_ip   = "public"
    frontend_port = "https"
    listener      = "https"
    backend_pool  = "llm-gateway-ilb"
    backend_http  = "llm-gateway-http"
    probe         = "llm-gateway-healthz"
    cert          = "llm-gateway-tls"
  }
}

resource "azurerm_application_gateway" "this" {
  name                = "agw-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  zones               = ["1", "2", "3"]
  firewall_policy_id  = azurerm_web_application_firewall_policy.this.id
  http2_enabled       = true
  tags                = local.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  # Scales to zero instances when idle (the fixed gateway cost remains).
  autoscale_configuration {
    min_capacity = 0
    max_capacity = 2
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw.id]
  }

  # TLS 1.2+ with strong ciphers only.
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101S"
  }

  gateway_ip_configuration {
    name      = "gateway"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_ip_configuration {
    name                 = local.agw.frontend_ip
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = local.agw.frontend_port
    port = 443
  }

  ssl_certificate {
    name                = local.agw.cert
    key_vault_secret_id = azurerm_key_vault_certificate.ingress.versionless_secret_id # follows auto-renewal
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
    ip_addresses = [local.ingress_ilb_ip]
  }

  probe {
    name                = local.agw.probe
    protocol            = "Http"
    host                = local.ingress_ilb_ip
    path                = "/healthz"
    interval            = 15
    timeout             = 5
    unhealthy_threshold = 3
    match {
      status_code = ["200"]
    }
  }

  # Hop to the ILB is HTTP inside the VNet; production with strict
  # end-to-end TLS: HTTPS backend + certificate on the app.
  backend_http_settings {
    name                  = local.agw.backend_http
    port                  = 80
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    request_timeout       = 60 # LLM responses can take a while
    probe_name            = local.agw.probe
  }

  request_routing_rule {
    name                       = "llm-gateway"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = local.agw.listener
    backend_address_pool_name  = local.agw.backend_pool
    backend_http_settings_name = local.agw.backend_http
  }

  depends_on = [time_sleep.appgw_rbac_propagation, azurerm_subnet_network_security_group_association.appgw]
}

# Access log + WAF log (every blocked request, with the rule that fired).
resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                           = "appgw-logs"
  target_resource_id             = azurerm_application_gateway.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }
}
