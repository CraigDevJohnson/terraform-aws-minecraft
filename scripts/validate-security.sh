#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Security check functions
check_iam_policies() {
    local policy_file="$1"
    local issues=0
    
    # Check for overly permissive actions
    if grep -q '"Action": "\*"' "$policy_file"; then
        echo -e "${YELLOW}WARNING: Found wildcard IAM actions${NC}"
        ((issues++))
    fi
    
    # Check for missing resource constraints
    if grep -q '"Resource": "\*"' "$policy_file"; then
        echo -e "${YELLOW}WARNING: Found wildcard resource definitions${NC}"
        ((issues++))
    fi
    
    return $issues
}

check_security_groups() {
    local sg_file="$1"
    local issues=0
    
    # Check for overly permissive ingress rules
    if grep -q '0\.0\.0\.0/0' "$sg_file"; then
        echo -e "${YELLOW}WARNING: Found open ingress rules${NC}"
        ((issues++))
    fi
    
    return $issues
}

check_encryption() {
    local issues=0
    
    # Check S3 encryption
    if ! grep -q 'server_side_encryption_configuration' storage.tf; then
        echo -e "${YELLOW}WARNING: S3 encryption might not be configured${NC}"
        ((issues++))
    fi
    
    # Check EBS encryption
    if ! grep -q 'encrypted.*=.*true' ec2.tf; then
        echo -e "${YELLOW}WARNING: EBS encryption might not be enabled${NC}"
        ((issues++))
    fi
    
    return $issues
}

check_logging() {
    local issues=0
    
    # Check CloudWatch logging
    if ! grep -q 'aws_cloudwatch_log_group' monitoring.tf; then
        echo -e "${YELLOW}WARNING: CloudWatch logging might not be configured${NC}"
        ((issues++))
    fi
    
    # Check VPC flow logs
    if ! grep -q 'aws_flow_log' network.tf; then
        echo -e "${YELLOW}WARNING: VPC Flow logs might not be enabled${NC}"
        ((issues++))
    }
    
    return $issues
}

check_backup_security() {
    local issues=0
    
    # Check backup encryption
    if ! grep -q 'kms_key_id' backup.tf; then
        echo -e "${YELLOW}WARNING: Backup encryption might not be configured${NC}"
        ((issues++))
    fi
    
    # Check backup access controls
    if ! grep -q 'aws_backup_vault_policy' backup.tf; then
        echo -e "${YELLOW}WARNING: Backup vault policy might not be set${NC}"
        ((issues++))
    fi
    
    return $issues
}

# Run security validation checks
run_security_checks() {
    local total_issues=0
    
    echo "Running security validation checks..."
    echo "===================================="
    
    # Check IAM policies
    echo -e "\nChecking IAM policies..."
    if check_iam_policies "iam.tf"; then
        echo -e "${GREEN}✓ IAM policies passed basic checks${NC}"
    else
        ((total_issues++))
    fi
    
    # Check security groups
    echo -e "\nChecking security groups..."
    if check_security_groups "network.tf"; then
        echo -e "${GREEN}✓ Security groups passed basic checks${NC}"
    else
        ((total_issues++))
    fi
    
    # Check encryption configuration
    echo -e "\nChecking encryption settings..."
    if check_encryption; then
        echo -e "${GREEN}✓ Encryption settings passed basic checks${NC}"
    else
        ((total_issues++))
    fi
    
    # Check logging configuration
    echo -e "\nChecking logging configuration..."
    if check_logging; then
        echo -e "${GREEN}✓ Logging configuration passed basic checks${NC}"
    else
        ((total_issues++))
    fi
    
    # Check backup security
    echo -e "\nChecking backup security..."
    if check_backup_security; then
        echo -e "${GREEN}✓ Backup security passed basic checks${NC}"
    else
        ((total_issues++))
    fi
    
    echo "===================================="
    echo "Security Check Summary:"
    echo "Total issues found: ${total_issues}"
    
    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}All security checks passed!${NC}"
        return 0
    else
        echo -e "${YELLOW}Security checks completed with warnings${NC}"
        return 1
    fi
}

# Execute security checks
run_security_checks