# Example values for the dev environment. Nothing here is secret.
# Replace the account, subnet and security group IDs with real ones before applying.
#
# A classic three-tier layout: 2 web servers -> 2 app servers -> 1 database.
#
#   web-1, web-2  stateless, behind a load balancer, rebuilt from the AMI at any time
#   app-1, app-2  stateless application tier, scaled and replaced freely
#   db            the ONLY stateful server: the data lives on its volume
#
# Losing a web or app server costs a redeploy. Losing the database costs the
# data, so db is the instance protected against deletion (README.md, Task 1).
#
# The assignment requires a different instance type, root volume type, root
# volume size and key pair for every instance. That is why the two servers of
# a tier differ from each other.

account_id  = "000000000000"
region      = "eu-west-1"
name_prefix = "arrise-dev"
environment = "dev"
owner       = "platform-team"

tags = {
  CostCenter = "devops-assignment"
}

# One map drives all five instances.
instances = {
  # --- Web tier (public traffic arrives through an ALB; the instances stay private)
  web-1 = {
    instance_type          = "t3.micro"
    key_name               = "arrise-dev-web-1"
    root_volume_type       = "gp3"
    root_volume_size       = 20
    root_volume_iops       = 3000
    root_volume_throughput = 125
    subnet_id              = "subnet-0a1b2c3d4e5f60001" # private, eu-west-1a
    vpc_security_group_ids = ["sg-0a1b2c3d4e5f6000a"]   # web-sg: 80/443 from the ALB only
    tags                   = { Tier = "web" }
  }

  web-2 = {
    instance_type          = "t3.small"
    key_name               = "arrise-dev-web-2"
    root_volume_type       = "standard" # magnetic: low I/O, serves mostly cached static content
    root_volume_size       = 16
    subnet_id              = "subnet-0a1b2c3d4e5f60002" # private, eu-west-1b
    vpc_security_group_ids = ["sg-0a1b2c3d4e5f6000a"]
    tags                   = { Tier = "web" }
  }

  # --- Application tier
  app-1 = {
    instance_type          = "c5.large"
    key_name               = "arrise-dev-app-1"
    root_volume_type       = "gp2"
    root_volume_size       = 30
    subnet_id              = "subnet-0a1b2c3d4e5f60001"
    vpc_security_group_ids = ["sg-0a1b2c3d4e5f6000b"] # app-sg: app port from web-sg only
    tags                   = { Tier = "app" }
  }

  app-2 = {
    instance_type          = "c5.xlarge"
    key_name               = "arrise-dev-app-2"
    root_volume_type       = "io1" # provisioned IOPS for heavy local scratch / cache I/O
    root_volume_size       = 40
    root_volume_iops       = 2000 # io1 allows up to 50 IOPS per GiB (40 x 50 = 2000)
    subnet_id              = "subnet-0a1b2c3d4e5f60002"
    vpc_security_group_ids = ["sg-0a1b2c3d4e5f6000b"]
    tags                   = { Tier = "app" }
  }

  # --- Data tier: stateful, protected against deletion
  db = {
    instance_type          = "r5.large" # memory-optimised for the database buffer cache
    key_name               = "arrise-dev-db"
    root_volume_type       = "io2" # consistent, provisioned IOPS and 99.999% durability
    root_volume_size       = 100
    root_volume_iops       = 5000 # io2 allows up to 1000 IOPS per GiB
    subnet_id              = "subnet-0a1b2c3d4e5f60001"
    vpc_security_group_ids = ["sg-0a1b2c3d4e5f6000c"] # db-sg: DB port from app-sg only
    prevent_destroy        = true
    tags                   = { Tier = "db" }
  }
}
