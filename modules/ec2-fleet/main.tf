# -----------------------------------------------------------------------------
# AMI lookup: latest Amazon Linux 2023 (x86_64), used by instances without ami_id.
# Only read when at least one instance needs it.
# -----------------------------------------------------------------------------
data "aws_ami" "al2023" {
  count = length(compact(values(var.instances)[*].ami_id)) < length(var.instances) ? 1 : 0

  owners      = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# -----------------------------------------------------------------------------
# Key pairs: created only for instances that pass a public_key. Otherwise the
# instance references an existing key pair by name. Private keys never touch
# Terraform (a tls_private_key resource would store the private key in state).
# -----------------------------------------------------------------------------
resource "aws_key_pair" "this" {
  for_each = { for k, v in var.instances : k => v if v.public_key != null }

  key_name   = each.value.key_name
  public_key = each.value.public_key

  tags = merge(var.tags, {
    Name        = each.value.key_name
    Environment = var.environment
    Owner       = var.owner
  })
}

locals {
  # Resolved, per-instance settings shared by both aws_instance resources below.
  resolved = {
    for k, v in var.instances : k => {
      ami_id             = coalesce(v.ami_id, one(data.aws_ami.al2023[*].id))
      key_name           = try(aws_key_pair.this[k].key_name, v.key_name) # module-created key pair if any
      security_group_ids = coalesce(v.vpc_security_group_ids, var.vpc_security_group_ids)

      # Mandatory tags are merged LAST so callers cannot override them.
      tags = merge(var.tags, v.tags, {
        Name        = "${var.name_prefix}-${k}"
        Environment = var.environment
        Owner       = var.owner
      })
    }
  }

  # Terraform does not allow lifecycle meta-arguments (prevent_destroy) to be
  # set from variables or per for_each key. The variable is therefore split
  # into two maps, one per resource block. Both blocks are still driven by the
  # single var.instances input.
  protected_instances   = { for k, v in var.instances : k => v if v.prevent_destroy }
  unprotected_instances = { for k, v in var.instances : k => v if !v.prevent_destroy }
}

# -----------------------------------------------------------------------------
# Regular (replaceable) instances.
# -----------------------------------------------------------------------------
resource "aws_instance" "this" {
  for_each = local.unprotected_instances

  ami                         = local.resolved[each.key].ami_id
  instance_type               = each.value.instance_type
  key_name                    = local.resolved[each.key].key_name
  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = local.resolved[each.key].security_group_ids
  iam_instance_profile        = each.value.iam_instance_profile
  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = var.detailed_monitoring
  disable_api_termination     = false

  # IMDSv2 only: blocks SSRF-style credential theft through IMDSv1.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = each.value.root_volume_type
    volume_size           = each.value.root_volume_size
    iops                  = each.value.root_volume_iops
    throughput            = each.value.root_volume_throughput
    encrypted             = true
    kms_key_id            = var.ebs_kms_key_id
    delete_on_termination = true
    tags                  = local.resolved[each.key].tags
  }

  tags = local.resolved[each.key].tags

  lifecycle {
    # A newer AMI must be rolled out on purpose (terraform apply -replace=...),
    # not as a side effect of the AMI data source moving forward.
    ignore_changes = [ami]

    precondition {
      condition     = length(local.resolved[each.key].security_group_ids) > 0
      error_message = "Instance \"${each.key}\" has no security groups. Set vpc_security_group_ids on the module or on the instance."
    }
  }
}

# -----------------------------------------------------------------------------
# Protected instances (prevent_destroy = true in var.instances).
#
# Two independent layers of protection:
#   1. lifecycle.prevent_destroy - Terraform refuses any plan that would destroy
#      or replace the instance (including terraform destroy).
#   2. disable_api_termination   - EC2 termination protection, which also stops
#      deletion from the console, CLI or another tool outside Terraform.
# The root volume is also kept if the instance is ever terminated.
# -----------------------------------------------------------------------------
resource "aws_instance" "protected" {
  for_each = local.protected_instances

  ami                         = local.resolved[each.key].ami_id
  instance_type               = each.value.instance_type
  key_name                    = local.resolved[each.key].key_name
  subnet_id                   = each.value.subnet_id
  vpc_security_group_ids      = local.resolved[each.key].security_group_ids
  iam_instance_profile        = each.value.iam_instance_profile
  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = var.detailed_monitoring
  disable_api_termination     = true

  # Explicitly false: with force_destroy = true the AWS provider (v6+) turns
  # termination protection off by itself before terminating, which would
  # defeat the protection above.
  force_destroy = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = each.value.root_volume_type
    volume_size           = each.value.root_volume_size
    iops                  = each.value.root_volume_iops
    throughput            = each.value.root_volume_throughput
    encrypted             = true
    kms_key_id            = var.ebs_kms_key_id
    delete_on_termination = false
    tags                  = local.resolved[each.key].tags
  }

  tags = local.resolved[each.key].tags

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami]

    precondition {
      condition     = length(local.resolved[each.key].security_group_ids) > 0
      error_message = "Instance \"${each.key}\" has no security groups. Set vpc_security_group_ids on the module or on the instance."
    }
  }
}
