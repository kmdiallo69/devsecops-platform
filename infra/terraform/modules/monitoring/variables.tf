variable "name" {
  description = "Name stem (e.g. llmgw-dev-frc-x1y2)."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "retention_in_days" {
  description = "Log retention (30-730)."
  type        = number
  default     = 30
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB; -1 = unlimited."
  type        = number
  default     = -1
}

variable "tags" {
  type    = map(string)
  default = {}
}
