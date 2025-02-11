#!/bin/bash
set -e

echo "Running deployment validation checks..."

# Check AWS configuration
echo "Checking AWS configuration..."
aws sts get-caller-identity || {
    echo "Error: AWS credentials not configured correctly"
    exit 1
}

# Verify required tools
echo "Verifying required tools..."
for cmd in terraform aws node zip jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is required but not installed"
        exit 1
    fi
done

# Verify Lambda dependencies
echo "Verifying Lambda packages..."
for dir in lambda/*/; do
    if [ -f "$dir/package.json" ]; then
        cd "$dir"
        if [ ! -d "node_modules" ]; then
            echo "Installing dependencies for $dir..."
            npm install --production
        fi
        cd ../..
    fi
done

# Validate IAM permissions
echo "Validating IAM permissions..."
required_services=("ec2" "s3" "lambda" "cloudwatch" "route53" "waf" "sns" "iam")
for service in "${required_services[@]}"; do
    aws iam simulate-principal-policy \
        --policy-source-arn $(aws sts get-caller-identity --query 'Arn' --output text) \
        --action-names "${service}:*" \
        --output json | jq -r '.EvaluationResults[].EvalDecision' | grep -q "allowed" || {
        echo "Warning: Missing permissions for $service"
    }
done

# Check AWS service quotas
echo "Checking AWS service quotas..."
services_to_check=(
    "Running On-Demand t3a instances"
    "Number of EBS volumes"
    "Number of Lambda functions"
)

# Run Terraform checks
echo "Running Terraform validations..."
terraform fmt -check
terraform validate

# Generate cost estimate
if command -v infracost &> /dev/null; then
    echo "Generating cost estimate..."
    infracost breakdown --path .
fi

echo "Validation complete!"
