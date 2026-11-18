resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version

  # Free control plane (no SLA) for a test cluster; production = Standard
  # (financially-backed SLA, more API server capacity).
  #checkov:skip=CKV_AZURE_170:SLA tier (Standard) not needed for an ephemeral test cluster
  sku_tier = "Free"

  # --- Identity & access ----------------------------------------------------
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # No static admin kubeconfig: every call is an Entra ID identity,
  # authorized by Azure RBAC and visible in the audit log.
  local_account_disabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  # PRIVATE cluster: the API server has a private IP in the VNet only — not
  # reachable from the Internet at all. Operators reach it with
  # `az aks command invoke` (through Azure Resource Manager, Entra ID +
  # RBAC, no network path needed) or from a bastion / VPN.
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  run_command_enabled                 = true

  # Pods get Entra ID tokens through federated identities (Step 8) —
  # no client secret anywhere.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # --- Data protection ------------------------------------------------------
  # Kubernetes Secrets in etcd encrypted with OUR key (CMK), versionless id =
  # follows the key's automatic rotation.
  key_management_service {
    key_vault_key_id         = azurerm_key_vault_key.etcd.versionless_id
    key_vault_network_access = "Public"
  }

  # Secrets Store CSI driver (Step 8), reaching Key Vault through its
  # private endpoint; re-read every 2 minutes so a rotation reaches pods.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  # --- Governance & visibility ---------------------------------------------
  # Azure Policy add-on = Gatekeeper managed by Azure (policy.tf).
  azure_policy_enabled = true

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48

  # --- Network --------------------------------------------------------------
  # Azure CNI overlay + Cilium (eBPF NetworkPolicies). Egress only through
  # the NAT Gateway of the node subnet — no public IP on the cluster.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    outbound_type       = "userAssignedNATGateway"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
  }

  # Node pools are declared here (Manual): every VM size and count is
  # reviewed in code.
  node_provisioning_profile {
    mode = "Manual"
  }

  # SYSTEM pool: cluster add-ons only (tainted CriticalAddonsOnly) — an
  # application pod never shares a node with kube-system.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.node_vm_size
    node_count                   = 1
    only_critical_addons_enabled = true
    vnet_subnet_id               = azurerm_subnet.nodes.id
    max_pods                     = 110
    os_sku                       = "AzureLinux"
    # OS disk on the VM's local NVMe: nothing persisted to remote storage,
    # faster, reimaged clean on every upgrade.
    os_disk_type = "Ephemeral"
    # Must fit the VM's local NVMe disk (110 GiB on D2ads_v7); the AKS
    # default of 128 GB is refused (VMCannotFitEphemeralOSDisk).
    os_disk_size_gb = 64
    #checkov:skip=CKV_AZURE_117:ephemeral OS disk = no managed disk to put a disk encryption set on; host encryption covers the VM host
    # Data at rest on the VM host encrypted too (temp disk, caches).
    host_encryption_enabled     = true
    node_public_ip_enabled      = false
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "1"
    }
  }

  depends_on = [
    azurerm_role_assignment.aks_kms,
    time_sleep.aks_rbac_propagation,
    azurerm_role_assignment.aks_network,
    azurerm_subnet_nat_gateway_association.nodes,
    azurerm_subnet_network_security_group_association.nodes,
  ]
  tags = local.tags

  lifecycle {
    ignore_changes = [kubernetes_version] # patched by the upgrade channel
  }
}

# USER pool: where application pods run.
resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                        = "apps"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.this.id
  mode                        = "User"
  vm_size                     = var.node_vm_size
  node_count                  = 1
  vnet_subnet_id              = azurerm_subnet.nodes.id
  max_pods                    = 110
  os_sku                      = "AzureLinux"
  os_disk_type                = "Ephemeral"
  os_disk_size_gb             = 64
  host_encryption_enabled     = true
  node_public_ip_enabled      = false
  temporary_name_for_rotation = "appstmp"

  # 2 nodes × 2 vCPU = the trial's whole 4-vCPU quota: a surge node during
  # an upgrade needs a quota increase (production: always request headroom).
  upgrade_settings {
    max_surge = "1"
  }

  tags = local.tags
}

# The cluster identity creates the app's internal load balancer in the node
# subnet — Network Contributor on THAT subnet only, not the VNet.
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# The operator is cluster admin through Azure RBAC — an auditable role
# assignment, not a shared certificate.
resource "azurerm_role_assignment" "operator_aks_admin" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Control-plane audit trail.
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "aks-audit"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "guard" # Entra ID / Azure RBAC authorization decisions
  }
}
