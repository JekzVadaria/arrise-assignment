variable "region" {
  description = "Region for the state bucket and lock table."
  type        = string
  default     = "eu-west-1"
}

variable "account_id" {
  description = "Account that owns the Terraform state (enforced by allowed_account_ids)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "name_prefix" {
  description = "Prefix used for the bucket, table and KMS alias names."
  type        = string
  default     = "arrise"
}

variable "noncurrent_version_retention_days" {
  description = "How long old state versions are kept for recovery before S3 expires them."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 30
    error_message = "Keep at least 30 days of state history."
  }
}
