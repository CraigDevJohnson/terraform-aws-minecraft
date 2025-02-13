# Terraform Configuration Block
# -----------------------
terraform {
  # Terraform version constraint
  required_version = ">= 1.0"

  # Required Provider Configurations
  required_providers {
    # AWS Provider for core infrastructure
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    
    # Random provider for unique resource naming
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }

    # TLS provider for SSH key generation
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    # Local provider for key file management
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }

  # S3 Backend Configuration
  # Uncomment and configure for remote state management
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "minecraft/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-lock"  # For state locking
  # }
}

# AWS Provider Configuration
# ------------------------
provider "aws" {
  region = var.region

  # Global tags applied to all resources
  default_tags {
    tags = merge(
      {
        Environment = var.environment
        Terraform   = "true"
        Project     = var.name
        ModuleVersion = "1.0.0"  # Update this when making breaking changes
      },
      var.additional_tags
    )
  }
}

# Data Sources
# -----------
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
