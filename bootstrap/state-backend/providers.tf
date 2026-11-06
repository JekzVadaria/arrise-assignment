provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Stack     = "bootstrap-state-backend"
      Purpose   = "terraform-remote-state"
    }
  }
}
