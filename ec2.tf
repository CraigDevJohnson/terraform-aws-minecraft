# AMI lookups
data "aws_ami" "amazon-linux-2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-minimal-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

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

// SSH Key configuration
resource "tls_private_key" "ec2_ssh" {
  count = length(var.key_name) > 0 ? 0 : 1

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2_ssh" {
  count = length(var.key_name) > 0 ? 0 : 1

  key_name   = "${var.name}-ec2-ssh-key"
  public_key = tls_private_key.ec2_ssh[0].public_key_openssh
}

locals {
  _ssh_key_name = length(var.key_name) > 0 ? var.key_name : aws_key_pair.ec2_ssh[0].key_name
  
  // AMI selection based on os_type variable
  selected_ami = {
    "amazon-linux-2"   = data.aws_ami.amazon-linux-2.id
    "amazon-linux-2023" = data.aws_ami.amazon-linux-2023.id
    "ubuntu"           = data.aws_ami.ubuntu.id
  }[var.os_type]

  instance_tags = merge(module.label.tags, {
    AutoShutdown      = var.enable_auto_shutdown
    ActiveHoursStart  = var.active_hours_start
    ActiveHoursEnd    = var.active_hours_end
    MinPlayersToStart = var.min_players_to_start
    ServerEdition     = var.server_edition
    DNSName           = var.create_dns_record ? var.domain_name : "none"
    OSType            = var.os_type
  })
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
    ManagedBy     = "terraform"
  })
}

// EC2 instance for the server - tune instance_type to fit your performance and budget requirements
module "ec2_minecraft" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "5.5.0"
  name    = "${var.name}-public"

  # instance
  key_name             = local._ssh_key_name
  ami                  = var.ami != "" ? var.ami : local.selected_ami
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.mc.id
  user_data            = data.template_file.user_data.rendered

  # network
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [module.ec2_security_group.this_security_group_id]
  associate_public_ip_address = var.associate_public_ip_address

  tags = local.instance_tags
}

// EBS volume
resource "aws_ebs_volume" "minecraft" {
  availability_zone = module.ec2_minecraft.availability_zone[0]
  size              = 30
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = merge(local.cost_tags, {
    Name = "${var.name}-minecraft-data"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "minecraft" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.minecraft.id
  instance_id = module.ec2_minecraft.id[0]
}

// Add automatic instance backup policy
resource "aws_dlm_lifecycle_policy" "minecraft" {
  description        = "Minecraft server volume backup policy"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "Daily snapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["23:00"]
      }

      retain_rule {
        count = 7 // Keep last 7 daily snapshots
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = true
    }

    target_tags = {
      Name = "${var.name}-minecraft-data"
    }
  }

  tags = local.cost_tags
}

// Add EBS volume configuration with optimized settings
resource "aws_ebs_volume" "minecraft" {
  availability_zone = module.ec2_minecraft.availability_zone[0]
  size              = 30
  type              = "gp3"
  iops              = 3000
  throughput        = 125

  encrypted = true

  tags = merge(local.cost_tags, {
    Name = "${var.name}-minecraft-data"
  })

  lifecycle {
    prevent_destroy = true // Prevent accidental deletion of game data
  }
}

resource "aws_volume_attachment" "minecraft" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.minecraft.id
  instance_id = module.ec2_minecraft.id[0]
}

// Add automated snapshot management
resource "aws_dlm_lifecycle_policy" "minecraft" {
  description        = "Minecraft server volume backup policy"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "Daily snapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["23:00"]
      }

      retain_rule {
        count = 7 // Keep last 7 daily snapshots
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = true
    }

    target_tags = {
      Name = "${var.name}-minecraft-data"
    }
  }

  tags = local.cost_tags
}

// Create EC2 ssh key pair
resource "tls_private_key" "ec2_ssh" {
  count = length(var.key_name) > 0 ? 0 : 1

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2_ssh" {
  count = length(var.key_name) > 0 ? 0 : 1

  key_name   = "${var.name}-ec2-ssh-key"
  public_key = tls_private_key.ec2_ssh[0].public_key_openssh
}