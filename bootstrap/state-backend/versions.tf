terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Chicken-and-egg: this stack creates the remote backend, so its own first
  # apply uses local state. After the first apply you can move its state into
  # the bucket it just created: uncomment the block below and run
  # `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   bucket         = "arrise-tfstate-000000000000-eu-west-1"
  #   key            = "bootstrap/state-backend/terraform.tfstate"
  #   region         = "eu-west-1"
  #   dynamodb_table = "arrise-terraform-locks"
  #   encrypt        = true
  #   kms_key_id     = "arn:aws:kms:eu-west-1:000000000000:alias/arrise-terraform-state"
  # }
}
