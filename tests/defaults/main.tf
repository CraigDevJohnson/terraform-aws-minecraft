terraform {
  required_version = ">= 1.0"
  required_providers {
    test = {
      source = "terraform.io/builtin/test"
    }
    http = {
      source = "hashicorp/http"
    }
    aws = {
      source = "hashicorp/aws"
    }
  }
}

module "main" {
  source = "../.."

  name        = "test-minecraft"
  environment = "test"
  
  # Network configuration
  allowed_cidrs = ["0.0.0.0/0"]
  
  # Server configuration
  server_edition = "bedrock"
  mc_version     = "latest"
  
  # Instance configuration
  instance_type = "t3a.small"
  
  # Testing-specific settings
  enable_auto_shutdown = true
  enable_monitoring    = true
  
  providers = {
    aws = aws
  }
}

resource "test_assertions" "ec2" {
  component = "ec2_instance"

  equal "instance_type" {
    description = "Check if instance type is t3a.small"
    got        = module.main.instance_type
    want       = "t3a.small"
  }

  check "instance_tags" {
    description = "Verify required tags are present"
    condition   = can(module.main.instance_tags["Environment"] == "test" && 
                     module.main.instance_tags["ManagedBy"] == "terraform")
  }
}

resource "test_assertions" "security_group" {
  component = "security_group"

  check "minecraft_port" {
    description = "Check if Bedrock port (19132) is open for UDP"
    condition   = can(module.main.security_group_rules["minecraft_bedrock"])
  }
}