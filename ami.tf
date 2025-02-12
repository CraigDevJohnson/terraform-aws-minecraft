// AMI lookup configurations for Minecraft server deployment
// These data sources allow for OS flexibility while ensuring use of latest stable versions

locals {
  os_owners = {
    amazon  = "amazon"    // Amazon Linux AMIs
    ubuntu  = "099720109477"  // Canonical's Ubuntu AMIs
  }
}

// Amazon Linux 2 AMI - Maintained for legacy support
// Used when backwards compatibility is required
data "aws_ami" "amazon-linux-2" {
  most_recent = true
  owners      = [local.os_owners.amazon]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

// Amazon Linux 2023 AMI - Default choice for new deployments
// Recommended for optimal performance and security
data "aws_ami" "amazon-linux-2023" {
  most_recent = true
  owners      = [local.os_owners.amazon]

  filter {
    name   = "name"
    values = ["al2023-ami-minimal-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

// Ubuntu 22.04 LTS AMI - Alternative option
// Useful for users who prefer Ubuntu-based deployments
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = [local.os_owners.ubuntu]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}
