# Stack: `ec2-fleet` (Tasks 1 and 2)

Root module that deploys a three-tier fleet (2 web, 2 app, 1 database) with the `modules/ec2-fleet` module. State is kept in S3 and locked with DynamoDB (`backend.tf`).

| Name | Tier | Instance type | Root volume | Size | Key pair | Protected |
|---|---|---|---|---|---|---|
| `arrise-dev-web-1` | web | t3.micro | gp3 (3000 IOPS / 125 MiB/s) | 20 GiB | arrise-dev-web-1 | |
| `arrise-dev-web-2` | web | t3.small | standard (magnetic) | 16 GiB | arrise-dev-web-2 | |
| `arrise-dev-app-1` | app | c5.large | gp2 | 30 GiB | arrise-dev-app-1 | |
| `arrise-dev-app-2` | app | c5.xlarge | **io1** (2000 IOPS) | 40 GiB | arrise-dev-app-2 | |
| `arrise-dev-db` | db | r5.large | **io2** (5000 IOPS) | 100 GiB | arrise-dev-db | **yes** |

The web and app tiers are stateless pairs, so either server can be replaced while its twin keeps serving. The database server is the single stateful instance, which is why it is the one protected against deletion.

Validation rules enforce the assignment's requirements at plan time:

- **module** (`modules/ec2-fleet/variables.tf`): at least one io1/io2 volume, valid boot volume types, IOPS only where valid;
- **stack** (`variables.tf`): exactly 5 instances; a different instance type, volume type, volume size and key pair for each; exactly one protected instance.

`tests/requirements.tftest.hcl` proves the committed `terraform.tfvars` passes these rules and that a non-compliant change is rejected.

## Run

```bash
# 1. Once per account: create the state bucket, lock table and KMS key
terraform -chdir=bootstrap/state-backend init
terraform -chdir=bootstrap/state-backend apply

# 2. Replace the placeholder subnet / SG / account IDs in terraform.tfvars, and
#    create the key pairs (or add public_key to each instance).
terraform -chdir=stacks/ec2-fleet init
terraform -chdir=stacks/ec2-fleet plan -out=tfplan
terraform -chdir=stacks/ec2-fleet apply tfplan
```

Example output:

```text
instance_ids = {
  "arrise-dev-app-1" = "i-0..."
  "arrise-dev-app-2" = "i-0..."
  "arrise-dev-db"    = "i-0..."
  "arrise-dev-web-1" = "i-0..."
  "arrise-dev-web-2" = "i-0..."
}
private_ips = {
  "arrise-dev-app-1" = "10.0.1.15"
  ...
}
```

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.10.0, < 2.0.0 |
| aws | ~> 6.0 |

### Modules

| Name | Source | Version |
|------|--------|---------|
| ec2\_fleet | ../../modules/ec2-fleet | n/a |

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| account\_id | AWS account the fleet must be deployed into (enforced by the provider's allowed\_account\_ids). | `string` | n/a | yes |
| instances | The five instances of the fleet (2 web, 2 app, 1 db). See modules/ec2-fleet for the field reference. | ```map(object({ instance_type = string key_name = string public_key = optional(string) root_volume_type = string root_volume_size = number root_volume_iops = optional(number) root_volume_throughput = optional(number) subnet_id = string ami_id = optional(string) vpc_security_group_ids = optional(list(string)) iam_instance_profile = optional(string) prevent_destroy = optional(bool, false) tags = optional(map(string), {}) }))``` | n/a | yes |
| owner | Owner tag value. | `string` | n/a | yes |
| environment | Environment tag value. | `string` | `"dev"` | no |
| name\_prefix | Prefix for instance Name tags. | `string` | `"arrise-dev"` | no |
| region | AWS Region for the fleet. | `string` | `"eu-west-1"` | no |
| tags | Extra tags for every instance. | `map(string)` | `{}` | no |
| vpc\_security\_group\_ids | Default security groups for instances that do not set their own. The example tfvars sets one security group per tier on each instance instead. | `list(string)` | `[]` | no |

### Outputs

| Name | Description |
|------|-------------|
| instance\_ids | Instance name -> instance ID. |
| private\_ips | Instance name -> private IP. |
| protected\_instance\_names | Instances protected against deletion. |
<!-- END_TF_DOCS -->
