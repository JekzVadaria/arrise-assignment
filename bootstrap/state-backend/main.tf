locals {
  bucket_name     = "${var.name_prefix}-tfstate-${var.account_id}-${var.region}"
  lock_table_name = "${var.name_prefix}-terraform-locks"
  kms_alias       = "alias/${var.name_prefix}-terraform-state"
}

# -----------------------------------------------------------------------------
# KMS key for the state bucket and lock table. State files can contain secrets
# (passwords, private keys, connection strings), so reading state requires
# kms:Decrypt on this key in addition to s3:GetObject.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "state_key" {
  # In a key policy, Resource "*" means "this key", not every resource.
  #checkov:skip=CKV_AWS_109:AWS default key policy; access is delegated to IAM policies in this account.
  #checkov:skip=CKV_AWS_111:AWS default key policy; access is delegated to IAM policies in this account.
  #checkov:skip=CKV_AWS_356:In a key policy "*" refers to the key itself.

  # Same as the AWS default key policy: lets IAM policies in this account
  # control access to the key. Without it the key could become unmanageable.
  statement {
    sid       = "EnableIAMPoliciesInThisAccount"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform remote state (${local.bucket_name}) and the lock table."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = local.kms_alias
  target_key_id = aws_kms_key.state.key_id
}

# -----------------------------------------------------------------------------
# S3 bucket holding the state files.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_144:Cross-region replication is out of scope here; versioning covers recovery.
  #checkov:skip=CKV2_AWS_62:Event notifications are not needed for a state bucket.
  #checkov:skip=CKV_AWS_18:Access logging needs a separate log bucket; CloudTrail S3 data events are the suggested follow-up.
  bucket = local.bucket_name

  # Losing this bucket means losing track of every resource Terraform manages.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced" # disables ACLs entirely
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning lets you roll back to an earlier state file if one is corrupted
# or overwritten by mistake.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Lifecycle rules apply to a versioned bucket only after versioning is on.
  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyOutdatedTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  # Avoid a race where the policy is applied before public access block.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# -----------------------------------------------------------------------------
# DynamoDB table for state locking.
# Terraform writes one item per state file (LockID = "<bucket>/<key>") with a
# conditional put, so only one plan/apply can hold the lock at a time.
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "locks" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST" # a handful of requests per run; no capacity to manage
  hash_key     = "LockID"          # attribute name required by the Terraform S3 backend

  deletion_protection_enabled = true

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  lifecycle {
    prevent_destroy = true
  }
}
