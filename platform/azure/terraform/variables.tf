variable "subscription_id" {
  description = "Subscription to deploy into (set in terraform.tfvars, git-ignored)."
  type        = string
}

variable "admin_ip" {
  description = "Public IPv4 of the operator: allowed to reach the WAF (test) — the API server itself is private."
  type        = string

  validation {
    condition     = can(cidrhost("${var.admin_ip}/32", 0))
    error_message = "admin_ip must be a single IPv4 address (no CIDR, no 0.0.0.0)."
  }
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "francecentral"
}

variable "node_vm_size" {
  description = "Node size: 2 vCPU / 8 GB, local NVMe disk (ephemeral OS disk). 2 nodes = a 4-vCPU trial quota."
  type        = string
  default     = "Standard_D2ads_v7"
}

variable "kubernetes_version" {
  description = "AKS minor version (patches applied automatically: automatic_upgrade_channel = patch)."
  type        = string
  default     = "1.36"
}

variable "allowed_image_regex" {
  description = "Azure Policy: the only container images allowed in application namespaces."
  type        = string
  default     = "^ghcr\\.io/kmdiallo69/.+@sha256:[a-f0-9]{64}$"
}

variable "ingress_allowed_cidrs" {
  description = "Sources allowed to reach the WAF on 443. null = the operator's IP only (test). Production: [\"0.0.0.0/0\"] — the WAF is the control."
  type        = list(string)
  default     = null
}
