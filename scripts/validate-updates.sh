#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Version validation functions
validate_server_version() {
    local instance_id=$1
    local expected_version=$2
    local server_edition=$3
    local issues=0
    
    echo "Validating server version..."
    
    # Get current version from instance metadata
    local current_version=$(aws ssm get-parameter \
        --name "/minecraft/${instance_id}/version" \
        --query "Parameter.Value" \
        --output text)
    
    if [ "$current_version" != "$expected_version" ]; then
        echo -e "${YELLOW}WARNING: Version mismatch - Expected: ${expected_version}, Got: ${current_version}${NC}"
        ((issues++))
    fi
    
    # Check version compatibility
    case $server_edition in
        "bedrock")
            # Verify protocol version for Bedrock
            local protocol_version=$(aws ssm get-parameter \
                --name "/minecraft/${instance_id}/protocol_version" \
                --query "Parameter.Value" \
                --output text)
            if [ -z "$protocol_version" ]; then
                echo -e "${YELLOW}WARNING: Unable to verify Bedrock protocol version${NC}"
                ((issues++))
            fi
            ;;
        "java")
            # Verify Java version compatibility
            local java_version=$(aws ssm get-parameter \
                --name "/minecraft/${instance_id}/java_version" \
                --query "Parameter.Value" \
                --output text)
            if [ -z "$java_version" ]; then
                echo -e "${YELLOW}WARNING: Unable to verify Java version${NC}"
                ((issues++))
            fi
            ;;
    esac
    
    return $issues
}

check_update_configuration() {
    local issues=0
    
    echo "Checking update configuration..."
    
    # Verify update checker Lambda
    if ! grep -q "aws_lambda_function.*version_checker" updates.tf; then
        echo -e "${YELLOW}WARNING: Version checker Lambda not configured${NC}"
        ((issues++))
    fi
    
    # Check update notification configuration
    if ! grep -q "aws_sns_topic.*minecraft_updates" updates.tf; then
        echo -e "${YELLOW}WARNING: Update notifications not configured${NC}"
        ((issues++))
    fi
    
    # Verify update schedule
    if ! grep -q "aws_cloudwatch_event_rule.*version_check" updates.tf; then
        echo -e "${YELLOW}WARNING: Update check schedule not configured${NC}"
        ((issues++))
    fi
    
    return $issues
}

validate_update_procedure() {
    local issues=0
    
    echo "Validating update procedure..."
    
    # Check backup before update
    if ! grep -q "pre_update_backup" user_data.sh; then
        echo -e "${YELLOW}WARNING: Pre-update backup not configured${NC}"
        ((issues++))
    fi
    
    # Check rollback capability
    if ! grep -q "rollback_update" user_data.sh; then
        echo -e "${YELLOW}WARNING: Update rollback not configured${NC}"
        ((issues++))
    fi
    
    # Verify update monitoring
    if ! grep -q "monitor_update_status" user_data.sh; then
        echo -e "${YELLOW}WARNING: Update monitoring not configured${NC}"
        ((issues++))
    fi
    
    return $issues
}

check_version_compatibility() {
    local issues=0
    
    echo "Checking version compatibility..."
    
    # Check mod compatibility if applicable
    if [ -f "mods.json" ]; then
        if ! jq -e '.compatible_versions' mods.json >/dev/null 2>&1; then
            echo -e "${YELLOW}WARNING: Mod version compatibility not specified${NC}"
            ((issues++))
        fi
    fi
    
    # Check world format compatibility
    if ! grep -q "check_world_compatibility" user_data.sh; then
        echo -e "${YELLOW}WARNING: World format compatibility check not configured${NC}"
        ((issues++))
    fi
    
    return $issues
}

run_update_validation() {
    local total_issues=0
    
    echo "Running update validation checks..."
    echo "=================================="
    
    # Check update configuration
    if ! check_update_configuration; then
        ((total_issues++))
    fi
    
    # Validate update procedure
    if ! validate_update_procedure; then
        ((total_issues++))
    fi
    
    # Check version compatibility
    if ! check_version_compatibility; then
        ((total_issues++))
    fi
    
    # Get instance details if available
    if [ -n "${AWS_DEFAULT_REGION:-}" ]; then
        instance_id=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=minecraft-*" \
            --query "Reservations[].Instances[?State.Name=='running'][].InstanceId" \
            --output text)
        
        if [ -n "$instance_id" ]; then
            if ! validate_server_version "$instance_id" "latest" "bedrock"; then
                ((total_issues++))
            fi
        fi
    fi
    
    echo "=================================="
    echo "Update Validation Summary:"
    echo "Total issues found: ${total_issues}"
    
    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}All update validation checks passed!${NC}"
        return 0
    else
        echo -e "${YELLOW}Update validation completed with warnings${NC}"
        return 1
    fi
}

# Execute update validation
run_update_validation