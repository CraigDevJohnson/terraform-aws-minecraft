#!/bin/bash
set -e

echo "Running infrastructure tests..."

# Test terraform configuration
echo "Validating terraform..."
terraform fmt -check -recursive
terraform validate

# Run static analysis
echo "Running static analysis..."
tflint
checkov -d .

# Test Lambda functions
echo "Testing Lambda functions..."
./scripts/test-lambda.sh

# Verify resource configurations
echo "Verifying resource configurations..."
terraform plan -detailed-exitcode

echo "Infrastructure tests completed!"
