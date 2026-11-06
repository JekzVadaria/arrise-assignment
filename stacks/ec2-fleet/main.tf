module "ec2_fleet" {
  source = "../../modules/ec2-fleet"

  name_prefix            = var.name_prefix
  environment            = var.environment
  owner                  = var.owner
  vpc_security_group_ids = var.vpc_security_group_ids
  tags                   = var.tags
  instances              = var.instances
}
