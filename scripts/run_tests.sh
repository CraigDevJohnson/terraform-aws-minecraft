#!/bin/bash
set -e

echo "Running Terraform validations..."
terraform init
terraform validate

echo "Running tflint..."
tflint

echo "Running security checks..."
checkov -d .

echo "Validating IAM policies..."
aws iam simulate-custom-policy --policy-input-list file://iam_policies_test.json

echo "Running cost estimation..."
terraform plan -out=tfplan
infracost breakdown --path tfplan

echo "All tests completed successfully!"
