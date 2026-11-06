provider "aws" {
  region = var.region

  # Guard rail: refuse to run against any account other than the intended one,
  # even if the operator's credentials point somewhere else.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "ec2-fleet"
    }
  }
}
