# =============================================================================
# Network — one VNet, one subnet per trust zone, an NSG on every subnet
# =============================================================================
#
#   Internet ──443──▶ [snet-appgw]  Application Gateway WAF_v2
#                          │ 80 (only rule allowed into the nodes)
#                          ▼
#                    [snet-aks-nodes] internal LB 10.10.3.250 ─▶ pods (overlay)
#                          │ outbound: NAT Gateway (one fixed public IP)
#                          │ 443
#                          ▼
#                    [snet-private-endpoints] Key Vault private endpoint
#
# Pods use the overlay network (192.168.0.0/16): they consume no VNet IPs
# and are not directly routable from the VNet — only through the ILB.

locals {
  vnet_cidr       = "10.10.0.0/16"
  nodes_cidr      = "10.10.0.0/22"
  appgw_cidr      = "10.10.4.0/24"
  pe_cidr         = "10.10.5.0/24"
  ingress_ilb_ip  = cidrhost(local.nodes_cidr, 1018) # 10.10.3.250, reserved for the app's internal LB
  ingress_sources = coalesce(var.ingress_allowed_cidrs, ["${var.admin_ip}/32"])
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [local.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.nodes_cidr]
  # No implicit internet access: egress exists ONLY through the NAT Gateway.
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.appgw_cidr]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.pe_cidr]
  # NSG rules apply to private endpoints too (off by default).
  private_endpoint_network_policies = "Enabled"
  default_outbound_access_enabled   = false
}

# --- NSG: Application Gateway ------------------------------------------------
resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-appgw-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  # HTTPS from the allowed sources only. Test: the operator's IP.
  # Production: Internet — the WAF is the control in front of the app.
  security_rule {
    name                       = "allow-https-in"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefixes    = local.ingress_sources
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "443"
  }

  # Required by Application Gateway v2 (Azure health/management traffic).
  security_rule {
    name                       = "allow-gateway-manager"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "GatewayManager"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "65200-65535"
  }

  security_rule {
    name                       = "allow-azure-lb"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }

  security_rule {
    name                       = "deny-all-in"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
}

# --- NSG: AKS nodes ----------------------------------------------------------
resource "azurerm_network_security_group" "nodes" {
  name                = "nsg-aks-nodes-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  # The ONLY way into the app: from the Application Gateway subnet, to the
  # app's internal load balancer, on its service port.
  security_rule {
    name                       = "allow-appgw-to-ingress-ilb"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = local.appgw_cidr
    source_port_range          = "*"
    destination_address_prefix = local.ingress_ilb_ip
    destination_port_range     = "80"
  }

  # Node-to-node and node-to-API-server (private endpoint in this subnet).
  security_rule {
    name                       = "allow-intra-subnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = local.nodes_cidr
    source_port_range          = "*"
    destination_address_prefix = local.nodes_cidr
    destination_port_range     = "*"
  }

  security_rule {
    name                       = "allow-azure-lb"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "AzureLoadBalancer"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }

  # Everything else — Internet AND the rest of the VNet — is refused
  # (overrides Azure's default "allow all VNet inbound").
  security_rule {
    name                       = "deny-all-in"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
}

# --- NSG: private endpoints --------------------------------------------------
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-pe-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  # Only the nodes (CSI driver) and the Application Gateway (its TLS
  # certificate) reach the private endpoints, only over TLS.
  # Found the hard way: inside the VNet, the gateway resolves the vault
  # through the privatelink zone like everyone else — without this rule it
  # cannot read its certificate, and fails after 20 minutes with a bare
  # "InternalServerError".
  security_rule {
    name                       = "allow-consumers-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefixes    = [local.nodes_cidr, local.appgw_cidr]
    source_port_range          = "*"
    destination_address_prefix = local.pe_cidr
    destination_port_range     = "443"
  }

  security_rule {
    name                       = "deny-all-in"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# --- Outbound: NAT Gateway ---------------------------------------------------
# All node/pod egress leaves through ONE known public IP: allowlistable by
# third parties, and no public IP on any node. (NAT gives a fixed egress
# address, not filtering: egress FILTERING by FQDN is Azure Firewall's job —
# the next production step, ~1.25 USD/hour.)
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "nat-${local.name}"
  location                = azurerm_resource_group.this.location
  resource_group_name     = azurerm_resource_group.this.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "nodes" {
  subnet_id      = azurerm_subnet.nodes.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# --- Private DNS for private endpoints ---------------------------------------
resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                 = "link-vnet"
  private_dns_zone_id  = azurerm_private_dns_zone.key_vault.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
}
