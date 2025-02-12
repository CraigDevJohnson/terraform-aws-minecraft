#!/bin/bash
set -euo pipefail

# Test configuration
TEST_ROOT="$(dirname "$0")/tests"
RESULTS_DIR="${TEST_ROOT}/results"
MODULES_DIR="${TEST_ROOT}/modules"

# Setup test environment
mkdir -p "${RESULTS_DIR}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Test functions
test_user_data() {
    echo "Testing user_data.sh..."
    
    # Create test environment
    TEST_DIR=$(mktemp -d)
    cp user_data.sh "${TEST_DIR}"
    cd "${TEST_DIR}"
    
    # Test OS detection
    bash -n user_data.sh
    
    # Test function outputs
    source user_data.sh >/dev/null 2>&1 || true
    
    # Test setup_system
    if declare -F setup_system >/dev/null; then
        echo "✓ setup_system function exists"
    else
        echo "✗ setup_system function missing"
        return 1
    fi
    
    # Test monitoring setup
    if grep -q 'setup_monitoring' user_data.sh; then
        echo "✓ monitoring configuration present"
    else
        echo "✗ monitoring configuration missing"
        return 1
    fi
    
    # Cleanup
    cd - >/dev/null
    rm -rf "${TEST_DIR}"
}

test_backup_system() {
    echo "Testing backup system..."
    
    # Test backup script
    if bash -n scripts/differential_backup.sh; then
        echo "✓ backup script syntax valid"
    else
        echo "✗ backup script syntax error"
        return 1
    fi
    
    # Test backup validation
    if grep -q 'validate_backup' scripts/differential_backup.sh; then
        echo "✓ backup validation present"
    else
        echo "✗ backup validation missing"
        return 1
    fi
}

test_monitoring_config() {
    echo "Testing monitoring configuration..."
    
    # Validate CloudWatch config
    if [ -f "monitoring.tf" ]; then
        if grep -q 'aws_cloudwatch_metric_alarm' monitoring.tf; then
            echo "✓ CloudWatch alarms configured"
        else
            echo "✗ CloudWatch alarms missing"
            return 1
        fi
    else
        echo "✗ monitoring.tf missing"
        return 1
    fi
}

test_security_configuration() {
    echo "Testing security configuration..."
    
    # Check WAF rules
    if [ -f "waf.tf" ]; then
        if grep -q 'aws_wafv2_web_acl' waf.tf; then
            echo "✓ WAF configuration present"
        else
            echo "✗ WAF configuration missing"
            return 1
        fi
    fi
    
    # Check security groups
    if grep -q 'aws_security_group' network.tf; then
        echo "✓ Security groups configured"
    else
        echo "✗ Security groups missing"
        return 1
    fi
}

# Run all tests
run_all_tests() {
    local failed=0
    
    echo "Starting infrastructure tests..."
    echo "================================"
    
    # Run each test function
    if test_user_data; then
        echo -e "${GREEN}✓ User data tests passed${NC}"
    else
        echo -e "${RED}✗ User data tests failed${NC}"
        ((failed++))
    fi
    
    if test_backup_system; then
        echo -e "${GREEN}✓ Backup system tests passed${NC}"
    else
        echo -e "${RED}✗ Backup system tests failed${NC}"
        ((failed++))
    fi
    
    if test_monitoring_config; then
        echo -e "${GREEN}✓ Monitoring tests passed${NC}"
    else
        echo -e "${RED}✗ Monitoring tests failed${NC}"
        ((failed++))
    fi
    
    if test_security_configuration; then
        echo -e "${GREEN}✓ Security tests passed${NC}"
    else
        echo -e "${RED}✗ Security tests failed${NC}}
        ((failed++))
    fi
    
    echo "================================"
    echo "Test Summary:"
    echo "Total tests: 4"
    echo "Failed: ${failed}"
    
    return $failed
}

# Execute tests
run_all_tests
