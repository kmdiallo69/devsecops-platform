variable "name" {
  description = "Name stem; the vault is kv-<name> (Key Vault names: max 24 characters)."
  type        = string

  validation {
    condition     = length("kv-${var.name}") <= 24
    error_message = "kv-<name> exceeds the 24-character Key Vault limit."
  }
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

variable "sku_name" {
  description = "standard (software keys) or premium (HSM-backed keys)."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "premium"], var.sku_name)
    error_message = "sku_name must be standard or premium."
  }
}

variable "administrator_object_ids" {
  description = "Entra ID objects granted Key Vault Administrator (data plane)."
  type        = list(string)
}

variable "soft_delete_retention_days" {
  type    = number
  default = 90
}

variable "key_rotation_days" {
  description = "Automatic rotation period of the etcd encryption key."
  type        = number
  default     = 90
}

variable "private_endpoint_subnet_id" {
  type = string
}

variable "private_dns_zone_id" {
  type = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
