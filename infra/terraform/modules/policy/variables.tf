variable "resource_group_id" {
  type = string
}

variable "effect" {
  description = "deny (enforce) or audit (report only)."
  type        = string
  default     = "deny"

  validation {
    condition     = contains(["deny", "audit"], var.effect)
    error_message = "effect must be deny or audit."
  }
}

variable "allowed_image_regex" {
  description = "The only container images allowed in application namespaces."
  type        = string
}

variable "excluded_namespaces" {
  description = <<-EOT
    Namespaces the policies do not apply to. Setting the parameter REPLACES
    Azure's default list, so the defaults are repeated, plus `aks-command`:
    where `az aks command invoke` (the admin path to a private cluster)
    runs its Microsoft-built pod — without it, the policies block our own
    admin access (RunCommandBlockedByGatekeeper). Who may use run command
    is controlled by Azure RBAC, not by this exemption.
  EOT
  type        = list(string)
  default = [
    "kube-system", "gatekeeper-system", "azure-arc", "azure-extensions-usage-system",
    "aks-command",
  ]
}
