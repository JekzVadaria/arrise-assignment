# Bootstrap: `state-backend` (Task 2)

Creates the remote-state infrastructure the other stacks use. Run it once per account, before anything else.

| Resource | Name | Hardening |
|---|---|---|
| KMS key + alias | `alias/arrise-terraform-state` | Yearly key rotation, 30-day deletion window, `prevent_destroy` |
| S3 bucket | `arrise-tfstate-<account>-<region>` | Versioning, SSE-KMS with a bucket key, Block Public Access, ACLs disabled, TLS 1.2+ only, old versions expired after 90 days, `prevent_destroy` |
| DynamoDB table | `arrise-terraform-locks` (`LockID` hash key) | On-demand billing, point-in-time recovery, KMS encryption, deletion protection, `prevent_destroy` |

This stack's own state starts out local, because the bucket does not exist yet. After the first apply, uncomment the backend block in `versions.tf` and run `terraform init -migrate-state` to move this state into the bucket.

```bash
terraform -chdir=bootstrap/state-backend init
terraform -chdir=bootstrap/state-backend apply
terraform -chdir=bootstrap/state-backend output -raw backend_config
```

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.10.0, < 2.0.0 |
| aws | ~> 6.0 |

### Providers

| Name | Version |
|------|---------|
| aws | ~> 6.0 |

### Resources

| Name | Type |
|------|------|
| [aws_dynamodb_table.locks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table) | resource |
| [aws_kms_alias.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_iam_policy_document.state_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.state_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| account\_id | Account that owns the Terraform state (enforced by allowed\_account\_ids). | `string` | n/a | yes |
| name\_prefix | Prefix used for the bucket, table and KMS alias names. | `string` | `"arrise"` | no |
| noncurrent\_version\_retention\_days | How long old state versions are kept for recovery before S3 expires them. | `number` | `90` | no |
| region | Region for the state bucket and lock table. | `string` | `"eu-west-1"` | no |

### Outputs

| Name | Description |
|------|-------------|
| backend\_config | Ready-to-paste backend block for a stack. Replace <stack> with the stack name. |
| kms\_alias\_arn | Alias ARN of the state KMS key (used as kms\_key\_id in backend blocks). |
| kms\_key\_arn | KMS key that encrypts state objects and the lock table. |
| lock\_table\_name | DynamoDB table used for state locking. |
| state\_bucket\_name | S3 bucket that stores Terraform state. |
<!-- END_TF_DOCS -->
