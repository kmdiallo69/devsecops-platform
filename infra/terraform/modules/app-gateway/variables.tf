variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  description = "Dedicated Application Gateway subnet (NSG attached)."
  type        = string
}

variable "key_vault_id" {
  description = "Vault holding the TLS certificate."
  type        = string
}

variable "backend_ip" {
  description = "The app's internal load balancer IP."
  type        = string
}

variable "health_probe_path" {
  type    = string
  default = "/healthz"
}

variable "tls_hostname" {
  description = "Hostname on the TLS certificate."
  type        = string
}

variable "waf_mode" {
  type    = string
  default = "Prevention"

  validation {
    condition     = contains(["Prevention", "Detection"], var.waf_mode)
    error_message = "waf_mode must be Prevention or Detection."
  }
}

variable "rate_limit_per_minute" {
  description = "Requests per client IP per minute before blocking."
  type        = number
  default     = 60
}

variable "autoscale" {
  type = object({
    min = number
    max = number
  })
  default = { min = 0, max = 2 }
}

variable "zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
