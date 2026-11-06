# Task 2 - Remote state in S3 with state locking in DynamoDB.
#
# The bucket, lock table and KMS key are created by bootstrap/state-backend
# (run that stack first; its `backend_config` output prints these values).
#
# Backend blocks cannot use variables, so the values are literal. To reuse this
# stack for another environment, keep `key` here and pass the rest with
# `terraform init -backend-config=<env>.s3.tfbackend`.
terraform {
  backend "s3" {
    bucket         = "arrise-tfstate-000000000000-eu-west-1"
    key            = "stacks/ec2-fleet/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "arrise-terraform-locks"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:eu-west-1:000000000000:alias/arrise-terraform-state"
  }
}
