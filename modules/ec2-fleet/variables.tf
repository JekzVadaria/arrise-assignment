variable "name_prefix" {
  description = "Prefix for every instance Name tag, e.g. \"arrise-dev\". The final Name is \"<name_prefix>-<instance key>\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must be 2-41 characters of lowercase letters, digits and hyphens."
  }
}

variable "environment" {
  description = "Environment name written to the Environment tag."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Team or person accountable for the instances, written to the Owner tag."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "vpc_security_group_ids" {
  description = "Default security groups attached to every instance. An instance can override this with its own vpc_security_group_ids."
  type        = list(string)
  default     = []
}

variable "ebs_kms_key_id" {
  description = "Optional KMS key ARN for root volume encryption. When null, the account's default EBS key (aws/ebs) is used. Volumes are always encrypted."
  type        = string
  default     = null
}

variable "detailed_monitoring" {
  description = "Enable 1-minute CloudWatch detailed monitoring on every instance."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags applied to every instance and root volume. Name, Environment and Owner are always set by the module and cannot be overridden here."
  type        = map(string)
  default     = {}
}

variable "instances" {
  description = <<-EOT
    The single input that drives the whole fleet. Map key = logical instance name.

    instance_type          - EC2 instance type, e.g. "t3.micro".
    key_name               - EC2 key pair name. If public_key is also set, the module creates the key pair.
    public_key             - Optional OpenSSH public key. Only the public half is ever given to Terraform.
    root_volume_type       - gp2 | gp3 | io1 | io2 | standard.
    root_volume_size       - Root volume size in GiB (8-16384).
    root_volume_iops       - Required for io1/io2, optional for gp3, not allowed otherwise.
    root_volume_throughput - Optional, gp3 only (MiB/s).
    subnet_id              - Private subnet to launch into.
    ami_id                 - Optional AMI. Defaults to the latest Amazon Linux 2023 x86_64 AMI.
    vpc_security_group_ids - Optional per-instance override of var.vpc_security_group_ids.
    iam_instance_profile   - Optional instance profile name (e.g. one with AmazonSSMManagedInstanceCore).
    prevent_destroy        - Protect this instance with lifecycle.prevent_destroy and EC2 termination protection.
    tags                   - Optional extra tags for this instance.
  EOT

  type = map(object({
    instance_type          = string
    key_name               = string
    public_key             = optional(string)
    root_volume_type       = string
    root_volume_size       = number
    root_volume_iops       = optional(number)
    root_volume_throughput = optional(number)
    subnet_id              = string
    ami_id                 = optional(string)
    vpc_security_group_ids = optional(list(string))
    iam_instance_profile   = optional(string)
    prevent_destroy        = optional(bool, false)
    tags                   = optional(map(string), {})
  }))

  validation {
    condition     = length(var.instances) > 0
    error_message = "At least one instance must be defined."
  }

  validation {
    condition     = alltrue([for k in keys(var.instances) : can(regex("^[a-z][a-z0-9-]{0,30}$", k))])
    error_message = "Instance keys must start with a letter and contain only lowercase letters, digits and hyphens (max 31 characters)."
  }

  validation {
    condition     = length(setsubtract(values(var.instances)[*].root_volume_type, ["gp2", "gp3", "io1", "io2", "standard"])) == 0
    error_message = "root_volume_type must be one of gp2, gp3, io1, io2, standard (st1/sc1 cannot be boot volumes)."
  }

  validation {
    condition     = min(values(var.instances)[*].root_volume_size...) >= 8 && max(values(var.instances)[*].root_volume_size...) <= 16384
    error_message = "root_volume_size must be between 8 and 16384 GiB."
  }

  # Task 1 requirement: at least one instance must use io1 or io2 storage.
  validation {
    condition     = length(setintersection(values(var.instances)[*].root_volume_type, ["io1", "io2"])) > 0
    error_message = "At least one instance must use io1 or io2 storage."
  }

  validation {
    condition     = alltrue([for v in values(var.instances) : v.root_volume_iops != null if contains(["io1", "io2"], v.root_volume_type)])
    error_message = "root_volume_iops is required when root_volume_type is io1 or io2 (provisioned IOPS)."
  }

  validation {
    condition     = alltrue([for v in values(var.instances) : v.root_volume_iops == null if !contains(["io1", "io2", "gp3"], v.root_volume_type)])
    error_message = "root_volume_iops can only be set for io1, io2 or gp3 volumes."
  }

  validation {
    condition     = alltrue([for v in values(var.instances) : v.root_volume_throughput == null if v.root_volume_type != "gp3"])
    error_message = "root_volume_throughput can only be set for gp3 volumes."
  }

  validation {
    condition     = alltrue([for k in values(var.instances)[*].key_name : trimspace(k) != ""])
    error_message = "Every instance needs a key_name."
  }

  validation {
    condition     = alltrue([for s in values(var.instances)[*].subnet_id : startswith(s, "subnet-")])
    error_message = "subnet_id must be a subnet ID (subnet-...)."
  }
}
