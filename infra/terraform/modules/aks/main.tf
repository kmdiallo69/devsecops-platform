# Private AKS cluster: Entra ID-only access, CMK-encrypted etcd, egress
# through the NAT Gateway, system and user pools separated.
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

# --- Cluster identity and its (minimal) permissions --------------------------
# User-assigned, so its permissions exist BEFORE the cluster is created.
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "id-aks-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# KMS uses the key to wrap/unwrap etcd encryption keys (DATA plane)...
resource "azurerm_role_assignment" "kms_crypto_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

# ...and AKS validates the vault through Azure Resource Manager before
# enabling KMS (Microsoft.KeyVault/vaults/read — CONTROL plane), which the
# data-plane role does not include. Found when cluster creation failed with
# AuthorizationFailed. Reader on this vault only.
resource "azurerm_role_assignment" "kms_vault_reader" {
  scope                = var.key_vault_id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

# Creates the app's internal load balancer — on the node subnet only.
resource "azurerm_role_assignment" "subnet_network_contributor" {
  scope                = var.nodes_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}

resource "time_sleep" "rbac_propagation" {
  depends_on = [
    azurerm_role_assignment.kms_crypto_user,
    azurerm_role_assignment.kms_vault_reader,
    azurerm_role_assignment.subnet_network_contributor,
  ]
  create_duration = "90s"
}

# --- Cluster ----------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version

  # Free (no SLA) in dev; Standard (financially-backed SLA, more API server
  # capacity) in staging/prod.
  #checkov:skip=CKV_AZURE_170:tier chosen per environment — Standard in staging/prod
  sku_tier = var.sku_tier

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }

  # No static admin kubeconfig: every call is an Entra ID identity,
  # authorized by Azure RBAC and visible in the audit log.
  local_account_disabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

  # PRIVATE cluster: API server on a private IP in the VNet only. Operators
  # use `az aks command invoke` (via Azure Resource Manager, Entra ID +
  # RBAC) or a bastion / VPN.
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  run_command_enabled                 = true

  # Pods get Entra ID tokens through federated identities — no client
  # secret anywhere (Step 8).
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Kubernetes Secrets in etcd encrypted with OUR key (CMK); versionless id
  # = follows the key's automatic rotation.
  key_management_service {
    key_vault_key_id         = var.etcd_key_versionless_id
    key_vault_network_access = "Public"
  }

  # Secrets Store CSI driver (Step 8): Key Vault secrets mounted as files,
  # re-read every 2 minutes so a rotation reaches pods.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  # Azure Policy add-on = Gatekeeper managed by Azure (modules/policy).
  azure_policy_enabled = true

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Removes unused (possibly vulnerable) images from the nodes.
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48

  # Azure CNI overlay + Cilium (eBPF NetworkPolicies); egress only through
  # the NAT Gateway of the node subnet — no public IP on the cluster.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    outbound_type       = "userAssignedNATGateway"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
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
    vm_size                      = var.system_pool.vm_size
    node_count                   = var.system_pool.node_count
    zones                        = length(var.system_pool.zones) > 0 ? var.system_pool.zones : null
    only_critical_addons_enabled = true
    vnet_subnet_id               = var.nodes_subnet_id
    max_pods                     = 110
    os_sku                       = "AzureLinux"
    # OS disk on the VM's local NVMe: nothing persisted remotely, reimaged
    # clean on every upgrade. Must fit the local disk (110 GiB on
    # D2ads_v7): the AKS default of 128 GB is refused.
    os_disk_type    = "Ephemeral"
    os_disk_size_gb = var.system_pool.os_disk_size_gb
    #checkov:skip=CKV_AZURE_117:ephemeral OS disk = no managed disk to put a disk encryption set on; host encryption covers the VM host
    # Temp disk and caches on the VM host encrypted too.
    host_encryption_enabled     = true
    node_public_ip_enabled      = false
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = var.system_pool.max_surge
    }
  }

  depends_on = [time_sleep.rbac_propagation]
  tags       = var.tags

  lifecycle {
    ignore_changes = [kubernetes_version] # patched by the upgrade channel
  }
}

# USER pool: where application pods run.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                        = "apps"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.this.id
  mode                        = "User"
  vm_size                     = var.user_pool.vm_size
  node_count                  = var.user_pool.node_count
  zones                       = length(var.user_pool.zones) > 0 ? var.user_pool.zones : null
  vnet_subnet_id              = var.nodes_subnet_id
  max_pods                    = 110
  os_sku                      = "AzureLinux"
  os_disk_type                = "Ephemeral"
  os_disk_size_gb             = var.user_pool.os_disk_size_gb
  host_encryption_enabled     = true
  node_public_ip_enabled      = false
  temporary_name_for_rotation = "appstmp"

  upgrade_settings {
    max_surge = var.user_pool.max_surge
  }

  # Destroy order: Terraform deletes in reverse dependency order, and the
  # admin role assignment only depended on the cluster — so it was deleted
  # IN PARALLEL with this pool, and operators lost kubectl access while the
  # pool was still draining (found during a real teardown). Depending on it
  # here keeps admin access until the pool is gone.
  depends_on = [azurerm_role_assignment.cluster_admins]

  tags = var.tags
}

# Cluster admins through Azure RBAC — auditable role assignments, not a
# shared certificate.
resource "azurerm_role_assignment" "cluster_admins" {
  for_each             = toset(var.administrator_object_ids)
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

# Control-plane audit trail.
resource "azurerm_monitor_diagnostic_setting" "this" {
  name                           = "aks-audit"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "guard" # Entra ID / Azure RBAC authorization decisions
  }
}
