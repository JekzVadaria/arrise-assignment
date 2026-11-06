locals {
  all_instances = merge(aws_instance.this, aws_instance.protected)
}

output "instance_ids" {
  description = "Map of instance name (the Name tag) to EC2 instance ID."
  value       = { for v in values(local.all_instances) : v.tags.Name => v.id }
}

output "private_ips" {
  description = "Map of instance name (the Name tag) to private IPv4 address."
  value       = { for v in values(local.all_instances) : v.tags.Name => v.private_ip }
}

output "protected_instance_names" {
  description = "Names of instances protected by lifecycle.prevent_destroy and EC2 termination protection."
  value       = sort(values(aws_instance.protected)[*].tags.Name)
}
