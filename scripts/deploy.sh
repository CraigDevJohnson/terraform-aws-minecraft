#!/bin/bash
set -e

echo "Preparing deployment..."

# Check prerequisites
command -v aws >/dev/null 2>&1 || { echo "AWS CLI is required but not installed. Aborting." >&2; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "Terraform is required but not installed. Aborting." >&2; exit 1; }

# Package Lambda functions
echo "Packaging Lambda functions..."
cd lambda/backup_validator && zip -r ../../backup_validator.zip . && cd ../..
cd lambda/activity_predictor && zip -r ../../activity_predictor.zip . && cd ../..

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Validate configuration
echo "Validating Terraform configuration..."
terraform validate

# Run security scan
echo "Running security scan..."
checkov -d .

# Plan deployment
echo "Planning deployment..."
terraform plan -out=tfplan

# Show cost estimate
if command -v infracost >/dev/null 2>&1; then
    echo "Generating cost estimate..."
    infracost breakdown --path tfplan
fi

echo "Deployment prepared successfully!"
echo "Review the plan and cost estimate above."
echo "To proceed with deployment, run: terraform apply tfplan"
