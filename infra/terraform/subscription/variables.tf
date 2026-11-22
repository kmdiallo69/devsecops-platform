variable "subscription_id" {
  description = "Target subscription (terraform.tfvars, git-ignored)."
  type        = string
}

variable "security_contact_email" {
  description = "Receives Defender for Cloud alerts (terraform.tfvars, git-ignored)."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.security_contact_email))
    error_message = "security_contact_email must be an email address."
  }
}

variable "enable_defender" {
  description = "Standard (paid, 30-day trial) Defender plans; false = back to Free."
  type        = bool
  default     = true
}
