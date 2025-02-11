terraform {
  required_version = ">= 1.0"

  # Add dependency validations
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# Add validation rules
locals {
  validate_instance_type = var.instance_type != "t3a.small" ? file("ERROR: Instance type must be t3a.small for optimal cost") : null
  validate_mc_port = var.server_edition == "bedrock" && var.mc_port != 19132 ? file("ERROR: Bedrock server must use port 19132") : null
}
