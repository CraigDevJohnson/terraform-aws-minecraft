# EC2 and related resources for Minecraft server
# ----------------------------------------

# AMI lookups for supported operating systems
data "aws_ami" "amazon-linux-2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

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
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# SSH Key configuration
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

# Local variables for EC2 configuration
locals {
  _ssh_key_name = length(var.key_name) > 0 ? var.key_name : aws_key_pair.ec2_ssh[0].key_name
  
  # AMI selection based on os_type variable
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

# User data template for instance configuration
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

# Security group for Minecraft server
resource "aws_security_group" "minecraft" {
  name        = "${var.name}-ec2"
  description = "Security group for Minecraft server"
  vpc_id      = local.vpc_id

  # Minecraft game port
  ingress {
    from_port   = var.mc_port
    to_port     = var.mc_port
    protocol    = var.server_edition == "bedrock" ? "udp" : "tcp"
    description = "Minecraft ${var.server_edition} access"
    cidr_blocks = var.allowed_cidrs
  }

  # SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    description = "SSH access"
    cidr_blocks = var.management_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(module.label.tags, {
    ServerEdition = var.server_edition
    ManagedBy     = "terraform"
  })
}

# EC2 instance for Minecraft server
resource "aws_instance" "minecraft" {
  ami                    = var.ami != "" ? var.ami : local.selected_ami
  instance_type          = var.instance_type
  key_name              = local._ssh_key_name
  iam_instance_profile  = aws_iam_instance_profile.mc.id
  user_data             = data.template_file.user_data.rendered
  subnet_id             = local.subnet_id
  vpc_security_group_ids = [aws_security_group.minecraft.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = local.instance_tags

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}

# EBS volume for game data
resource "aws_ebs_volume" "minecraft" {
  availability_zone = aws_instance.minecraft.availability_zone
  size             = 30
  type             = "gp3"
  iops             = 3000
  throughput       = 125
  encrypted        = true

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
  instance_id = aws_instance.minecraft.id
}

# Automated backup configuration
resource "aws_dlm_lifecycle_policy" "minecraft" {
  description        = "Minecraft server volume backup policy"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state             = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "Daily snapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times        = ["23:00"]
      }

      retain_rule {
        count = 7 # Keep last 7 daily snapshots
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