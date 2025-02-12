#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test result tracking
declare -A TEST_RESULTS
TOTAL_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_name="$1"
    local test_script="$2"
    
    echo -e "\n${YELLOW}Running ${test_name}...${NC}"
    echo "============================================"
    
    if bash "$test_script"; then
        TEST_RESULTS[$test_name]="PASS"
        echo -e "${GREEN}✓ ${test_name} passed${NC}"
    else
        TEST_RESULTS[$test_name]="FAIL"
        echo -e "${RED}✗ ${test_name} failed${NC}"
        ((FAILED_TESTS++))
    fi
    
    ((TOTAL_TESTS++))
}

generate_report() {
    local report_file="test-results.md"
    
    echo "# Infrastructure Test Results" > "$report_file"
    echo "## Test Summary" >> "$report_file"
    echo "- Total Tests: ${TOTAL_TESTS}" >> "$report_file"
    echo "- Failed Tests: ${FAILED_TESTS}" >> "$report_file"
    echo "" >> "$report_file"
    
    echo "## Detailed Results" >> "$report_file"
    for test in "${!TEST_RESULTS[@]}"; do
        echo "### ${test}" >> "$report_file"
        if [ "${TEST_RESULTS[$test]}" == "PASS" ]; then
            echo "✅ PASSED" >> "$report_file"
        else
            echo "❌ FAILED" >> "$report_file"
        fi
        echo "" >> "$report_file"
    done
    
    # Add test execution time
    echo "## Test Execution Time" >> "$report_file"
    echo "$(date '+%Y-%m-%d %H:%M:%S')" >> "$report_file"
}

main() {
    echo "Starting infrastructure validation suite..."
    
    # Infrastructure tests
    run_test "Infrastructure Tests" "./scripts/test-infrastructure.sh"
    
    # Security validation
    run_test "Security Validation" "./scripts/validate-security.sh"
    
    # Monitoring validation
    run_test "Monitoring Validation" "./scripts/validate-monitoring.sh"
    
    # Update validation
    run_test "Update Validation" "./scripts/validate-updates.sh"
    
    # Generate test report
    generate_report
    
    echo -e "\n============================================"
    echo "Test Summary:"
    echo "Total Tests: ${TOTAL_TESTS}"
    echo "Failed Tests: ${FAILED_TESTS}"
    
    if [ $FAILED_TESTS -eq 0 ]; then
        echo -e "${GREEN}All tests passed successfully!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed. Check test-results.md for details.${NC}"
        exit 1
    fi
}

main