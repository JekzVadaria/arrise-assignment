# Verifies the committed terraform.tfvars (2 web, 2 app, 1 db) meets every
# Task 1 requirement, and that each stack-level rule rejects a violating change.
# The "at least one io1/io2" rule lives in the module and is tested there.
# Run with `terraform init -backend=false && terraform test`. The provider is
# mocked, so no AWS access is needed.

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
}

# Declared so the negative tests below can derive a broken map from the
# committed terraform.tfvars value.
variable "instances" {
  type = any
}

run "committed_tfvars_meet_all_requirements" {
  command = apply

  assert {
    condition     = length(output.instance_ids) == 5 && length(output.private_ips) == 5
    error_message = "The stack must output IDs and private IPs for exactly 5 instances."
  }

  assert {
    condition     = output.protected_instance_names == tolist(["arrise-dev-db"])
    error_message = "The database server must be the one protected instance."
  }

  assert {
    condition     = sort(keys(output.instance_ids)) == tolist(["arrise-dev-app-1", "arrise-dev-app-2", "arrise-dev-db", "arrise-dev-web-1", "arrise-dev-web-2"])
    error_message = "Output keys must be the instance names."
  }
}

run "rejects_duplicate_instance_type" {
  command = plan

  variables {
    instances = merge(var.instances, {
      web-2 = merge(var.instances["web-2"], { instance_type = "t3.micro" }) # same as web-1
    })
  }

  expect_failures = [var.instances]
}

run "rejects_duplicate_key_pair" {
  command = plan

  variables {
    instances = merge(var.instances, {
      app-2 = merge(var.instances["app-2"], { key_name = "arrise-dev-app-1" })
    })
  }

  expect_failures = [var.instances]
}

run "rejects_more_than_one_protected_instance" {
  command = plan

  variables {
    instances = merge(var.instances, {
      web-1 = merge(var.instances["web-1"], { prevent_destroy = true })
    })
  }

  expect_failures = [var.instances]
}

run "rejects_wrong_number_of_instances" {
  command = plan

  variables {
    instances = { for k, v in var.instances : k => v if k != "web-2" }
  }

  expect_failures = [var.instances]
}
