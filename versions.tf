terraform {
  required_version = ">= 1.0"

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

provider "aws" {
  # Configuration options
}

# Run Lambda build script before terraform plan/apply
resource "null_resource" "build_lambdas" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/build_lambdas.sh"
  }
}

# Make other resources depend on Lambda builds
locals {
  lambda_build_completed = null_resource.build_lambdas.id
}
