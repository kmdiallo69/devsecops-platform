# =============================================================================
# Network — one VNet, one subnet per trust zone, an NSG on every subnet
# =============================================================================
#
#   Internet ──443──▶ [snet-appgw]  Application Gateway WAF_v2
#                          │ 80 (only rule allowed into the nodes)
#                          ▼
#                    [snet-aks-nodes] internal LB (.3.250) ─▶ pods (overlay)
#                          │ outbound: NAT Gateway (one fixed public IP)
#                          │ 443
#                          ▼
#                    [snet-private-endpoints] Key Vault private endpoint
#
# Subnets are DERIVED from the environment's /16 (dev 10.10, staging 10.20,
# prod 10.30): no overlap, so environments can be peered to a hub later.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.14"
    }
  }
}

locals {
  nodes_cidr     = cidrsubnet(var.address_space, 6, 0) # x.x.0.0/22
  appgw_cidr     = cidrsubnet(var.address_space, 8, 4) # x.x.4.0/24
  pe_cidr        = cidrsubnet(var.address_space, 8, 5) # x.x.5.0/24
  ingress_ilb_ip = cidrhost(local.nodes_cidr, 1018)    # x.x.3.250, reserved for the app's internal LB

  deny_all_inbound = {
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

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.nodes_cidr]
  # No implicit internet access: egress exists ONLY through the NAT Gateway.
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.appgw_cidr]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.pe_cidr]
  # NSG rules apply to private endpoints too (off by default).
  private_endpoint_network_policies = "Enabled"
  default_outbound_access_enabled   = false
}

# --- NSG: Application Gateway ------------------------------------------------
resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-appgw-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  # HTTPS from the allowed sources only (dev/staging: operator / corporate
  # ranges; prod: Internet — the WAF is the control in front of the app).
  security_rule {
    name                       = "allow-https-in"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefixes    = var.ingress_allowed_cidrs
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
    name                       = local.deny_all_inbound.name
    priority                   = local.deny_all_inbound.priority
    direction                  = local.deny_all_inbound.direction
    access                     = local.deny_all_inbound.access
    protocol                   = local.deny_all_inbound.protocol
    source_address_prefix      = local.deny_all_inbound.source_address_prefix
    source_port_range          = local.deny_all_inbound.source_port_range
    destination_address_prefix = local.deny_all_inbound.destination_address_prefix
    destination_port_range     = local.deny_all_inbound.destination_port_range
  }
}

# --- NSG: AKS nodes ----------------------------------------------------------
resource "azurerm_network_security_group" "nodes" {
  name                = "nsg-aks-nodes-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

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

  # Pod-to-pod across nodes. With Azure CNI OVERLAY, a pod's packets keep
  # their POD IP on the wire between nodes. Found the hard way: without this
  # rule, deny-all-in silently dropped every cross-node pod packet —
  # starting with DNS to CoreDNS on the system node.
  security_rule {
    name                       = "allow-pod-cidr"
    priority                   = 115
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = var.pod_cidr
    source_port_range          = "*"
    destination_address_prefix = "*"
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
    name                       = local.deny_all_inbound.name
    priority                   = local.deny_all_inbound.priority
    direction                  = local.deny_all_inbound.direction
    access                     = local.deny_all_inbound.access
    protocol                   = local.deny_all_inbound.protocol
    source_address_prefix      = local.deny_all_inbound.source_address_prefix
    source_port_range          = local.deny_all_inbound.source_port_range
    destination_address_prefix = local.deny_all_inbound.destination_address_prefix
    destination_port_range     = local.deny_all_inbound.destination_port_range
  }
}

# --- NSG: private endpoints --------------------------------------------------
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-pe-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  # Only the nodes (CSI driver) and the Application Gateway (its TLS
  # certificate) reach the private endpoints, only over TLS. Found the hard
  # way: inside the VNet the gateway resolves the vault through the
  # privatelink zone like everyone else — without this, it cannot read its
  # certificate and fails after 20 minutes with a bare "InternalServerError".
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
    name                       = local.deny_all_inbound.name
    priority                   = local.deny_all_inbound.priority
    direction                  = local.deny_all_inbound.direction
    access                     = local.deny_all_inbound.access
    protocol                   = local.deny_all_inbound.protocol
    source_address_prefix      = local.deny_all_inbound.source_address_prefix
    source_port_range          = local.deny_all_inbound.source_port_range
    destination_address_prefix = local.deny_all_inbound.destination_address_prefix
    destination_port_range     = local.deny_all_inbound.destination_port_range
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
# third parties, no public IP on any node. NAT gives a fixed egress address,
# not filtering: egress filtering by FQDN is Azure Firewall's job (the next
# production step, ~1.25 USD/hour).
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "nat-${var.name}"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = var.tags
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
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                 = "link-vnet"
  private_dns_zone_id  = azurerm_private_dns_zone.key_vault.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
}
