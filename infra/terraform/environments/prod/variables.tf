variable "subscription_id" {
  description = "Target subscription (terraform.tfvars, git-ignored)."
  type        = string
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
