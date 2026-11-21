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

variable "llm_api_key" {
  description = "LLM provider API key — pass via TF_VAR_llm_api_key, never a file. Ephemeral: not stored in plan or state."
  type        = string
  default     = null
  sensitive   = true
  ephemeral   = true
}

variable "llm_api_key_version" {
  description = "Bump to rotate the key in Key Vault."
  type        = number
  default     = 1
}
