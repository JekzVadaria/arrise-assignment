output "state_bucket_name" {
  description = "S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table_name" {
  description = "DynamoDB table used for state locking."
  value       = aws_dynamodb_table.locks.name
}

output "kms_key_arn" {
  description = "KMS key that encrypts state objects and the lock table."
  value       = aws_kms_key.state.arn
}

output "kms_alias_arn" {
  description = "Alias ARN of the state KMS key (used as kms_key_id in backend blocks)."
  value       = aws_kms_alias.state.arn
}

output "backend_config" {
  description = "Ready-to-paste backend block for a stack. Replace <stack> with the stack name."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.bucket}"
        key            = "stacks/<stack>/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.locks.name}"
        encrypt        = true
        kms_key_id     = "${aws_kms_alias.state.arn}"
      }
    }
  EOT
}
