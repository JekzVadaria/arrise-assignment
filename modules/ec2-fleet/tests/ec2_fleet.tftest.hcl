# Offline unit tests: `terraform test` from modules/ec2-fleet.
# The AWS provider is mocked, so no credentials or network calls are needed.

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
}

variables {
  name_prefix            = "test"
  environment            = "dev"
  owner                  = "platform-team"
  vpc_security_group_ids = ["sg-0123456789abcdef0"]

  instances = {
    web = {
      instance_type    = "t3.micro"
      key_name         = "web-key"
      root_volume_type = "gp3"
      root_volume_size = 20
      subnet_id        = "subnet-0123456789abcdef0"
    }
    db = {
      instance_type    = "m5.large"
      key_name         = "db-key"
      public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockKeyForTestsOnly test@example"
      root_volume_type = "io2"
      root_volume_size = 100
      root_volume_iops = 5000
      subnet_id        = "subnet-0123456789abcdef1"
      prevent_destroy  = true
    }
  }
}

run "protected_instance_is_split_into_its_own_resource" {
  command = plan

  assert {
    condition     = keys(aws_instance.this) == ["web"]
    error_message = "Only the unprotected instance should be in aws_instance.this."
  }

  assert {
    condition     = keys(aws_instance.protected) == ["db"]
    error_message = "Only the protected instance should be in aws_instance.protected."
  }

  assert {
    condition     = aws_instance.protected["db"].disable_api_termination == true
    error_message = "The protected instance must also have EC2 termination protection."
  }

  assert {
    condition     = aws_instance.protected["db"].root_block_device[0].delete_on_termination == false
    error_message = "The protected instance must keep its root volume if it is ever terminated."
  }

  assert {
    condition     = aws_instance.protected["db"].force_destroy == false
    error_message = "force_destroy must stay false, or the provider would lift termination protection on destroy."
  }

  assert {
    condition     = aws_instance.this["web"].disable_api_termination == false
    error_message = "Unprotected instances must stay replaceable."
  }
}

run "every_instance_has_mandatory_tags" {
  command = plan

  variables {
    # Callers must not be able to override the mandatory tags.
    tags = {
      Owner      = "someone-else"
      CostCenter = "1234"
    }
  }

  assert {
    condition = alltrue([
      for inst in concat(values(aws_instance.this), values(aws_instance.protected)) :
      inst.tags["Environment"] == "dev" && inst.tags["Owner"] == "platform-team" && startswith(inst.tags["Name"], "test-")
    ])
    error_message = "Every instance needs Name, Environment and Owner tags set by the module."
  }

  assert {
    condition     = aws_instance.this["web"].tags["CostCenter"] == "1234"
    error_message = "Extra tags should still be passed through."
  }

  assert {
    condition     = aws_instance.protected["db"].root_block_device[0].tags["Name"] == "test-db"
    error_message = "Root volumes should carry the same tags as their instance."
  }
}

run "security_baseline" {
  command = plan

  assert {
    condition = alltrue([
      for inst in concat(values(aws_instance.this), values(aws_instance.protected)) :
      inst.metadata_options[0].http_tokens == "required"
    ])
    error_message = "IMDSv2 must be enforced on every instance."
  }

  assert {
    condition = alltrue([
      for inst in concat(values(aws_instance.this), values(aws_instance.protected)) :
      inst.root_block_device[0].encrypted == true
    ])
    error_message = "Every root volume must be encrypted."
  }

  assert {
    condition = alltrue([
      for inst in concat(values(aws_instance.this), values(aws_instance.protected)) :
      inst.associate_public_ip_address == false
    ])
    error_message = "Instances must not get a public IP."
  }
}

run "volume_settings_are_passed_per_instance" {
  command = plan

  assert {
    condition     = aws_instance.protected["db"].root_block_device[0].volume_type == "io2" && aws_instance.protected["db"].root_block_device[0].iops == 5000
    error_message = "io2 volume type and IOPS were not applied."
  }

  assert {
    condition     = aws_instance.this["web"].root_block_device[0].volume_size == 20 && aws_instance.this["web"].instance_type == "t3.micro"
    error_message = "Instance type or volume size was not applied."
  }
}

run "key_pair_is_created_only_when_public_key_is_given" {
  command = plan

  assert {
    condition     = keys(aws_key_pair.this) == ["db"]
    error_message = "Only instances with a public_key should get a managed key pair."
  }

  assert {
    condition     = aws_instance.this["web"].key_name == "web-key" && aws_instance.protected["db"].key_name == "db-key"
    error_message = "Instances must use their own key pair."
  }
}

run "outputs_are_keyed_by_instance_name" {
  command = apply

  assert {
    condition     = sort(keys(output.instance_ids)) == tolist(["test-db", "test-web"])
    error_message = "instance_ids must be keyed by instance Name."
  }

  assert {
    condition     = sort(keys(output.private_ips)) == tolist(["test-db", "test-web"])
    error_message = "private_ips must be keyed by instance Name."
  }

  assert {
    condition     = output.protected_instance_names == tolist(["test-db"])
    error_message = "protected_instance_names should list only the db instance."
  }
}

run "rejects_fleet_without_io1_or_io2_volume" {
  command = plan

  variables {
    instances = {
      web = {
        instance_type    = "t3.micro"
        key_name         = "web-key"
        root_volume_type = "gp3"
        root_volume_size = 20
        subnet_id        = "subnet-0123456789abcdef0"
      }
      db = {
        instance_type    = "m5.large"
        key_name         = "db-key"
        root_volume_type = "gp2"
        root_volume_size = 100
        subnet_id        = "subnet-0123456789abcdef1"
      }
    }
  }

  expect_failures = [var.instances]
}

run "rejects_provisioned_iops_volume_without_iops" {
  command = plan

  variables {
    instances = {
      db = {
        instance_type    = "m5.large"
        key_name         = "db-key"
        root_volume_type = "io1"
        root_volume_size = 50
        subnet_id        = "subnet-0123456789abcdef0"
      }
    }
  }

  expect_failures = [var.instances]
}

run "rejects_non_bootable_volume_type" {
  command = plan

  variables {
    instances = {
      web = {
        instance_type    = "t3.micro"
        key_name         = "web-key"
        root_volume_type = "st1"
        root_volume_size = 125
        subnet_id        = "subnet-0123456789abcdef0"
      }
    }
  }

  expect_failures = [var.instances]
}

run "rejects_instance_without_security_groups" {
  command = plan

  variables {
    vpc_security_group_ids = []
  }

  expect_failures = [aws_instance.this, aws_instance.protected]
}
