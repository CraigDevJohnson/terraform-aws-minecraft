#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
WORKSPACE="testing"
PLAN_FILE="deployment-test.tfplan"
STATE_FILE="test-state.tfstate"

test_terraform_configuration() {
    local issues=0
    
    echo "Testing Terraform configuration..."
    
    # Initialize Terraform
    terraform init -backend=false
    
    # Select test workspace
    terraform workspace select "$WORKSPACE" || terraform workspace new "$WORKSPACE"
    
    # Validate configuration
    if ! terraform validate; then
        echo -e "${RED}✗ Terraform validation failed${NC}"
        ((issues++))
    fi
    
    # Run plan
    if ! terraform plan -out="$PLAN_FILE"; then
        echo -e "${RED}✗ Terraform plan failed${NC}"
        ((issues++))
    fi
    
    return $issues
}

test_resource_dependencies() {
    local issues=0
    
    echo "Checking resource dependencies..."
    
    # Critical dependencies
    local dependencies=(
        "aws_iam_role.minecraft"
        "aws_security_group.minecraft"
        "aws_s3_bucket.minecraft"
        "aws_cloudwatch_log_group.minecraft"
    )
    
    for dep in "${dependencies[@]}"; do
        if ! terraform state show "$dep" &>/dev/null; then
            echo -e "${YELLOW}WARNING: Missing dependency: ${dep}${NC}"
            ((issues++))
        fi
    done
    
    return $issues
}

test_variable_validation() {
    local issues=0
    
    echo "Testing variable validation..."
    
    # Test required variables
    if ! terraform plan -var="server_edition=invalid" 2>/dev/null; then
        echo -e "${GREEN}✓ Server edition validation working${NC}"
    else
        echo -e "${RED}✗ Server edition validation failed${NC}"
        ((issues++))
    fi
    
    # Test memory allocation validation
    if ! terraform plan -var="java_mx_mem=invalid" 2>/dev/null; then
        echo -e "${GREEN}✓ Memory allocation validation working${NC}"
    else
        echo -e "${RED}✗ Memory allocation validation failed${NC}"
        ((issues++))
    fi
    
    return $issues
}

test_outputs() {
    local issues=0
    
    echo "Testing output values..."
    
    # Required outputs
    local outputs=(
        "public_ip"
        "instance_id"
        "bucket_name"
    )
    
    for output in "${outputs[@]}"; do
        if ! terraform output "$output" &>/dev/null; then
            echo -e "${YELLOW}WARNING: Missing output: ${output}${NC}"
            ((issues++))
        fi
    done
    
    return $issues
}

validate_deployment() {
    local total_issues=0
    
    echo "Running deployment validation..."
    echo "==============================="
    
    # Test Terraform configuration
    if ! test_terraform_configuration; then
        ((total_issues++))
    fi
    
    # Test resource dependencies
    if ! test_resource_dependencies; then
        ((total_issues++))
    fi
    
    # Test variable validation
    if ! test_variable_validation; then
        ((total_issues++))
    fi
    
    # Test outputs
    if ! test_outputs; then
        ((total_issues++))
    fi
    
    echo "==============================="
    echo "Deployment Validation Summary:"
    echo "Total issues found: ${total_issues}"
    
    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}All deployment checks passed!${NC}"
        return 0
    else
        echo -e "${YELLOW}Deployment checks completed with warnings${NC}"
        return 1
    fi
}

cleanup() {
    echo "Cleaning up test resources..."
    
    # Remove test workspace
    terraform workspace select default
    terraform workspace delete -force "$WORKSPACE"
    
    # Remove test files
    rm -f "$PLAN_FILE" "$STATE_FILE"
}

main() {
    # Ensure cleanup runs on exit
    trap cleanup EXIT
    
    # Run deployment validation
    validate_deployment
}