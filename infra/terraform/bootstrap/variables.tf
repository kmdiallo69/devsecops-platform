variable "subscription_id" {
  description = "Target subscription (terraform.tfvars, git-ignored)."
  type        = string
}

variable "admin_ip" {
  description = "Operator public IPv4 — the only address allowed to reach the state account."
  type        = string

  validation {
    condition     = can(cidrhost("${var.admin_ip}/32", 0))
    error_message = "admin_ip must be a single IPv4 address."
  }
}

variable "location" {
  type    = string
  default = "francecentral"
}

variable "delete_lock" {
  description = "CanNotDelete lock on the state account (true in any shared setup)."
  type        = bool
  default     = true
}
