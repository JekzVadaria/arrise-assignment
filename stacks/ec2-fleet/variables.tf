variable "region" {
  description = "AWS Region for the fleet."
  type        = string
  default     = "eu-west-1"
}

variable "account_id" {
  description = "AWS account the fleet must be deployed into (enforced by the provider's allowed_account_ids)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "name_prefix" {
  description = "Prefix for instance Name tags."
  type        = string
  default     = "arrise-dev"
}

variable "environment" {
  description = "Environment tag value."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "vpc_security_group_ids" {
  description = "Default security groups for instances that do not set their own. The example tfvars sets one security group per tier on each instance instead."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Extra tags for every instance."
  type        = map(string)
  default     = {}
}

# Same shape as the module input. The validations below encode the assignment
# requirements for THIS stack, so a non-compliant tfvars change fails at plan
# time instead of in code review. The module itself stays generic.
variable "instances" {
  description = "The five instances of the fleet (2 web, 2 app, 1 db). See modules/ec2-fleet for the field reference."

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
    condition     = length(var.instances) == 5
    error_message = "This stack must define exactly 5 instances."
  }

  # One rule for all four "must differ per instance" attributes.
  validation {
    condition = alltrue([
      for attr in ["instance_type", "root_volume_type", "root_volume_size", "key_name"] :
      length(distinct([for v in values(var.instances) : v[attr]])) == length(var.instances)
    ])
    error_message = "instance_type, root_volume_type, root_volume_size and key_name must each be different on every instance."
  }

  # "At least one io1/io2 instance" is enforced by the module's own
  # validation (modules/ec2-fleet/variables.tf).

  validation {
    condition     = length([for v in values(var.instances) : v if v.prevent_destroy]) == 1
    error_message = "Exactly one instance must be protected with prevent_destroy (see README.md, Task 1)."
  }
}
