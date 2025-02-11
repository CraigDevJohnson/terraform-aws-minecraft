terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }

  # Uncomment and configure if you want to use remote state
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "minecraft/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = var.environment
      Terraform   = "true"
      Project     = var.name
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "aws" {}
