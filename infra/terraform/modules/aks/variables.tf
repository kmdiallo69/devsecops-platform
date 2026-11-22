variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "kubernetes_version" {
  description = "Minor version; patches are applied by the upgrade channel."
  type        = string
}

variable "sku_tier" {
  type    = string
  default = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "administrator_object_ids" {
  description = "Entra ID objects granted AKS RBAC Cluster Admin."
  type        = list(string)
}

variable "nodes_subnet_id" {
  type = string
}

variable "pod_cidr" {
  type = string
}

variable "service_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "172.16.0.10"
}

variable "key_vault_id" {
  type = string
}

variable "etcd_key_versionless_id" {
  type = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "system_pool" {
  description = "System node pool (add-ons only)."
  type = object({
    vm_size         = string
    node_count      = number
    zones           = optional(list(string), [])
    os_disk_size_gb = optional(number, 64)
    max_surge       = optional(string, "1")
  })
}

variable "user_pool" {
  description = "User node pool (application pods)."
  type = object({
    vm_size         = string
    node_count      = number
    zones           = optional(list(string), [])
    os_disk_size_gb = optional(number, 64)
    max_surge       = optional(string, "1")
  })
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "defender_sensor_enabled" {
  description = "Deploy the Defender for Containers sensor (needs the subscription's Containers plan)."
  type        = bool
  default     = true
}
