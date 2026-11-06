output "instance_ids" {
  description = "Instance name -> instance ID."
  value       = module.ec2_fleet.instance_ids
}

output "private_ips" {
  description = "Instance name -> private IP."
  value       = module.ec2_fleet.private_ips
}

output "protected_instance_names" {
  description = "Instances protected against deletion."
  value       = module.ec2_fleet.protected_instance_names
}
