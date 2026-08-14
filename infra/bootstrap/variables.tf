variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Name prefix for the state bucket."
  type        = string
  default     = "techstream"
}

variable "noncurrent_version_retention_days" {
  description = "How long to keep noncurrent state versions before expiring them."
  type        = number
  default     = 90
}

variable "noncurrent_versions_to_keep" {
  description = "Always keep at least this many noncurrent versions, regardless of age."
  type        = number
  default     = 10
}

variable "create_dynamodb_lock_table" {
  description = <<-EOT
    Leave false on Terraform 1.10 or newer and use S3-native locking
    (use_lockfile = true in the backend block). Set true only if you must run
    an older Terraform, which needs a DynamoDB table for locking.
  EOT
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = <<-EOT
    Optional customer managed KMS key ARN for state encryption. Leave null to
    use SSE-S3 (AES256), which is enough for this lab and costs nothing.
  EOT
  type        = string
  default     = null
}
