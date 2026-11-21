variable "subscription_id" {
  description = "Target subscription (terraform.tfvars, git-ignored)."
  type        = string
}

variable "admin_ip" {
  description = "Operator public IPv4, allowed to reach the WAF."
  type        = string

  validation {
    condition     = can(cidrhost("${var.admin_ip}/32", 0))
    error_message = "admin_ip must be a single IPv4 address."
  }
}
