variable "workload" {
  description = "Short workload name used in every resource name."
  type        = string
  default     = "llmgw"
}

variable "environment" {
  type = string

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "environment must be dev, stg or prd."
  }
}

variable "location" {
  type = string
}

variable "location_short" {
  description = "Region code used in names (e.g. frc = francecentral)."
  type        = string
}

variable "address_space" {
  description = "The environment's /16 — distinct per environment."
  type        = string
}

variable "ingress_allowed_cidrs" {
  description = "Sources allowed to reach the WAF on 443."
  type        = list(string)
}

variable "extra_administrator_object_ids" {
  description = "Entra ID groups/users granted admin, in addition to the identity running Terraform."
  type        = list(string)
  default     = []
}

variable "kubernetes_version" {
  type = string
}

variable "aks_sku_tier" {
  type = string
}

variable "system_pool" {
  type = object({
    vm_size         = string
    node_count      = number
    zones           = optional(list(string), [])
    os_disk_size_gb = optional(number, 64)
    max_surge       = optional(string, "1")
  })
}

variable "user_pool" {
  type = object({
    vm_size         = string
    node_count      = number
    zones           = optional(list(string), [])
    os_disk_size_gb = optional(number, 64)
    max_surge       = optional(string, "1")
  })
}

variable "key_vault_sku" {
  type    = string
  default = "standard"
}

variable "key_vault_soft_delete_days" {
  type = number
}

variable "log_retention_days" {
  type = number
}

variable "log_daily_quota_gb" {
  type = number
}

variable "tls_hostname" {
  type = string
}

variable "waf_mode" {
  type    = string
  default = "Prevention"
}

variable "waf_rate_limit_per_minute" {
  type    = number
  default = 60
}

variable "appgw_autoscale" {
  type = object({
    min = number
    max = number
  })
}

variable "policy_effect" {
  type    = string
  default = "deny"
}

variable "allowed_image_regex" {
  description = "Only our signed images, by digest."
  type        = string
  default     = "^ghcr\\.io/kmdiallo69/.+@sha256:[a-f0-9]{64}$"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "llm_api_key" {
  description = "LLM provider API key. Ephemeral + write-only: never in plan or state. null = placeholder."
  type        = string
  default     = null
  sensitive   = true
  ephemeral   = true
}

variable "llm_api_key_version" {
  description = "Bump to push a new llm_api_key."
  type        = number
  default     = 1
}

variable "defender_sensor_enabled" {
  description = "Defender for Containers sensor on AKS (subscription plan in infra/terraform/subscription)."
  type        = bool
  default     = true
}
