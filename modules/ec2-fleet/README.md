# Module: `ec2-fleet` (Task 1)

Creates any number of EC2 instances from **one map variable** (`instances`). Each instance has its own instance type, root volume type, size and IOPS, and key pair. Any instance can be marked `prevent_destroy = true` to protect it against deletion.

## Usage

```hcl
module "ec2_fleet" {
  source = "../../modules/ec2-fleet"

  name_prefix            = "arrise-dev"
  environment            = "dev"
  owner                  = "platform-team"
  vpc_security_group_ids = ["sg-0123456789abcdef0"]

  instances = {
    web = {
      instance_type    = "t3.micro"
      key_name         = "arrise-dev-web"
      root_volume_type = "gp3"
      root_volume_size = 20
      subnet_id        = "subnet-0123456789abcdef0"
    }
    db = {
      instance_type    = "m5.large"
      key_name         = "arrise-dev-db"
      root_volume_type = "io2"
      root_volume_size = 100
      root_volume_iops = 5000
      subnet_id        = "subnet-0123456789abcdef1"
      prevent_destroy  = true
    }
  }
}
```

## What every instance gets

| Control | Setting | Why |
|---|---|---|
| Tags | `Name`, `Environment`, `Owner` on the instance **and** its root volume. Merged last, so callers cannot override them. | Cost allocation, ownership, search |
| IMDSv2 | `http_tokens = "required"`, hop limit 1 | Blocks SSRF-style theft of instance credentials through IMDSv1 |
| Encryption | Root volume always encrypted (default `aws/ebs` key or `ebs_kms_key_id`) | Data at rest |
| Network | `associate_public_ip_address = false` | Instances are private; reach them through SSM Session Manager or a VPN |
| AMI | Latest Amazon Linux 2023 unless `ami_id` is set; `ignore_changes = [ami]` | A new AMI release must not silently replace the fleet |
| Key pairs | Existing key pair by name, or created from a **public** key | The private key never enters Terraform state |

## How protection works

Terraform does not let `lifecycle { prevent_destroy = ... }` take a variable or vary per `for_each` key. The module therefore splits `var.instances` into two maps that feed two resource blocks:

| Resource | Gets | Protection |
|---|---|---|
| `aws_instance.this` | instances with `prevent_destroy = false` | none (replaceable) |
| `aws_instance.protected` | instances with `prevent_destroy = true` | `lifecycle.prevent_destroy` + EC2 termination protection (`disable_api_termination`) + root volume kept on termination |

Both blocks are still driven by the single `instances` input. The root [README](../../README.md#task-1--multi-instance-ec2-provisioning) explains which instance is protected and why.

## Tests

`terraform init && terraform test` runs offline against a mocked AWS provider. The tests check the protected/unprotected split, mandatory tags, the security baseline, per-instance volume settings, key pair handling, output shape, and the input validations.

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.10.0, < 2.0.0 |
| aws | >= 6.0, < 7.0 |

### Providers

| Name | Version |
|------|---------|
| aws | >= 6.0, < 7.0 |

### Resources

| Name | Type |
|------|------|
| [aws_instance.protected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_key_pair.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/key_pair) | resource |
| [aws_ami.al2023](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| environment | Environment name written to the Environment tag. | `string` | n/a | yes |
| instances | The single input that drives the whole fleet. Map key = logical instance name.  instance\_type          - EC2 instance type, e.g. "t3.micro". key\_name               - EC2 key pair name. If public\_key is also set, the module creates the key pair. public\_key             - Optional OpenSSH public key. Only the public half is ever given to Terraform. root\_volume\_type       - gp2 \| gp3 \| io1 \| io2 \| standard. root\_volume\_size       - Root volume size in GiB (8-16384). root\_volume\_iops       - Required for io1/io2, optional for gp3, not allowed otherwise. root\_volume\_throughput - Optional, gp3 only (MiB/s). subnet\_id              - Private subnet to launch into. ami\_id                 - Optional AMI. Defaults to the latest Amazon Linux 2023 x86\_64 AMI. vpc\_security\_group\_ids - Optional per-instance override of var.vpc\_security\_group\_ids. iam\_instance\_profile   - Optional instance profile name (e.g. one with AmazonSSMManagedInstanceCore). prevent\_destroy        - Protect this instance with lifecycle.prevent\_destroy and EC2 termination protection. tags                   - Optional extra tags for this instance. | ```map(object({ instance_type = string key_name = string public_key = optional(string) root_volume_type = string root_volume_size = number root_volume_iops = optional(number) root_volume_throughput = optional(number) subnet_id = string ami_id = optional(string) vpc_security_group_ids = optional(list(string)) iam_instance_profile = optional(string) prevent_destroy = optional(bool, false) tags = optional(map(string), {}) }))``` | n/a | yes |
| name\_prefix | Prefix for every instance Name tag, e.g. "arrise-dev". The final Name is "<name\_prefix>-<instance key>". | `string` | n/a | yes |
| owner | Team or person accountable for the instances, written to the Owner tag. | `string` | n/a | yes |
| detailed\_monitoring | Enable 1-minute CloudWatch detailed monitoring on every instance. | `bool` | `true` | no |
| ebs\_kms\_key\_id | Optional KMS key ARN for root volume encryption. When null, the account's default EBS key (aws/ebs) is used. Volumes are always encrypted. | `string` | `null` | no |
| tags | Extra tags applied to every instance and root volume. Name, Environment and Owner are always set by the module and cannot be overridden here. | `map(string)` | `{}` | no |
| vpc\_security\_group\_ids | Default security groups attached to every instance. An instance can override this with its own vpc\_security\_group\_ids. | `list(string)` | `[]` | no |

### Outputs

| Name | Description |
|------|-------------|
| instance\_ids | Map of instance name (the Name tag) to EC2 instance ID. |
| private\_ips | Map of instance name (the Name tag) to private IPv4 address. |
| protected\_instance\_names | Names of instances protected by lifecycle.prevent\_destroy and EC2 termination protection. |
<!-- END_TF_DOCS -->
