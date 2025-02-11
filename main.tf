// This module creates a single EC2 instance for running a Minecraft server

// Default network
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = local.vpc_id
}

data "aws_caller_identity" "aws" {}

locals {
  vpc_id    = length(var.vpc_id) > 0 ? var.vpc_id : data.aws_vpc.default.id
  subnet_id = length(var.subnet_id) > 0 ? var.subnet_id : sort(data.aws_subnet_ids.default.ids)[0]
  bucket    = "${var.name}-minecraft-${data.aws_caller_identity.current.account_id}"
  tf_tags = {
    Terraform   = "true"
    Environment = var.environment
    Project     = var.name
    ManagedBy   = "terraform"
  }

  # Basic validation
  validate_dns = var.create_dns_record && (var.zone_id == "" || var.domain_name == "") ? file("ERROR: When create_dns_record is true, both zone_id and domain_name must be provided") : null
  validate_backup_replication = var.enable_backup_replication && var.backup_replica_bucket_arn == "" ? file("ERROR: When enable_backup_replication is true, backup_replica_bucket_arn must be provided") : null
}

// Amazon Linux2 AMI - can switch this to default by editing the EC2 resource below
data "aws_ami" "amazon-linux-2" {
  most_recent = true

  owners = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*"]
  }
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

// Amazon Linux 2023 AMI
data "aws_ami" "amazon-linux-2023" {
  most_recent = true

  owners = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "name"
    values = ["al2023-ami-minimal-*-x86_64"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

// Find latest Ubuntu AMI, use as default if no AMI specified
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] // Canonical
}

// Script to configure the server - this is where most of the magic occurs!
data "template_file" "user_data" {
  template = file("${path.module}/user_data.sh")

  vars = {
    mc_root        = var.mc_root
    mc_bucket      = local.bucket
    mc_backup_freq = var.mc_backup_freq
    mc_version     = var.mc_version
    mc_type        = var.mc_type   
    java_mx_mem    = var.java_mx_mem
    java_ms_mem    = var.java_ms_mem
  }
}

// Security group for our instance - allows SSH and minecraft 
module "ec2_security_group" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-security-group.git?ref=master"

  name        = "${var.name}-ec2"
  description = "Allow game ports for Minecraft server"
  vpc_id      = local.vpc_id

  ingress_rules = []
  
  ingress_with_cidr_blocks = [
    {
      from_port   = var.mc_port
      to_port     = var.mc_port
      protocol    = var.server_edition == "bedrock" ? "udp" : "tcp"
      description = "Minecraft ${var.server_edition} access"
      cidr_blocks = join(",", var.allowed_cidrs)
    }
  ]

  egress_rules = ["all-all"]

  tags = merge(module.label.tags, {
    ServerEdition = var.server_edition
    ManagedBy = "terraform"
  })
}

locals {
  _ssh_key_name = length(var.key_name) > 0 ? var.key_name : aws_key_pair.ec2_ssh[0].key_name
}

// EC2 instance for the server - tune instance_type to fit your performance and budget requirements
locals {
  instance_tags = merge(module.label.tags, {
    AutoShutdown = var.enable_auto_shutdown
    ActiveHoursStart = var.active_hours_start
    ActiveHoursEnd = var.active_hours_end
    MinPlayersToStart = var.min_players_to_start
    ServerEdition = var.server_edition
    DNSName = var.create_dns_record ? var.domain_name : "none"
  })
}

module "ec2_minecraft" {
  source = "terraform-aws-modules/ec2-instance/aws"
  version = "5.5.0"
  name   = "${var.name}-public"

  # instance
  key_name             = local._ssh_key_name
  ami                  = var.ami != "" ? var.ami : data.aws_ami.amazon-linux-2023.id
  instance_type        = "t3a.small"  # Changed from larger instance
  iam_instance_profile = aws_iam_instance_profile.mc.id
  user_data            = data.template_file.user_data.rendered

  # network
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [ module.ec2_security_group.this_security_group_id ]
  associate_public_ip_address = var.associate_public_ip_address

  tags = local.instance_tags
}

// Core module configuration
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace   = var.namespace
  stage      = var.environment
  name       = var.name
  delimiter  = "-"
  label_order = ["namespace", "stage", "name", "attributes"]
  tags       = merge(var.tags, local.tf_tags)
}

// Core data sources and locals
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
