variable "name" {
  description = "Environment name stem."
  type        = string
}

variable "app_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer (Workload Identity federation)."
  type        = string
}

variable "namespace" {
  type = string
}

variable "service_account" {
  type = string
}

variable "key_vault_id" {
  type = string
}

variable "secret_name" {
  type = string
}

variable "secret_value" {
  description = "The secret. Ephemeral: never stored in plan or state. null = random placeholder."
  type        = string
  default     = null
  sensitive   = true
  ephemeral   = true
}

variable "secret_version" {
  description = "Bump to push a new secret_value (write-only attributes are not diffed)."
  type        = number
  default     = 1
}

variable "secret_max_age_days" {
  type    = number
  default = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
