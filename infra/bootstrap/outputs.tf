output "state_bucket_name" {
  description = "Put this in the bucket field of the S3 backend block in ../terraform/versions.tf."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "region" {
  description = "Region for the backend block."
  value       = var.region
}

output "lock_table_name" {
  description = "DynamoDB lock table name, null when using S3-native locking."
  value       = var.create_dynamodb_lock_table ? aws_dynamodb_table.lock[0].name : null
}

output "backend_block" {
  description = "Copy-paste backend configuration for the main config."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.state.id}"
        key          = "techstream/terraform.tfstate"
        region       = "${var.region}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}
