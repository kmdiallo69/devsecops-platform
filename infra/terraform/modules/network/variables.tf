variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  description = "The environment's /16 (subnets are derived from it)."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.address_space)) && endswith(var.address_space, "/16")
    error_message = "address_space must be a /16, e.g. 10.10.0.0/16."
  }
}

variable "pod_cidr" {
  description = "AKS overlay pod range (outside the VNet), allowed between nodes."
  type        = string
}

variable "ingress_allowed_cidrs" {
  description = "Sources allowed to reach the WAF on 443."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
