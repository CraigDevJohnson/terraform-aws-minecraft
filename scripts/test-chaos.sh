#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Chaos test configuration
RECOVERY_WAIT=300  # 5 minutes to check recovery
MAX_FAILURES=3     # Maximum number of simultaneous failures

# Chaos scenarios
declare -A CHAOS_SCENARIOS=(
    ["network_partition"]="Simulate network connectivity issues"
    ["cpu_stress"]="Simulate high CPU load"
    ["memory_pressure"]="Simulate memory pressure"
    ["disk_pressure"]="Simulate disk pressure"
    ["service_failure"]="Simulate service crashes"
)

inject_failure() {
    local scenario=$1
    local instance_id=$2
    local issues=0
    
    echo "Injecting failure: ${scenario}"
    
    case $scenario in
        "network_partition")
            # Add network latency and packet loss
            aws ssm send-command \
                --document-name "AWS-RunShellScript" \
                --targets "Key=InstanceIds,Values=${instance_id}" \
                --parameters "commands=['tc qdisc add dev eth0 root netem loss 20% delay 100ms']" \
                --comment "Inject network issues"
            ;;
        "cpu_stress")
            # Create CPU load
            aws ssm send-command \
                --document-name "AWS-RunShellScript" \
                --targets "Key=InstanceIds,Values=${instance_id}" \
                --parameters "commands=['stress-ng --cpu 4 --timeout 300s &']" \
                --comment "Inject CPU stress"
            ;;
        "memory_pressure")
            # Create memory pressure
            aws ssm send-command \
                --document-name "AWS-RunShellScript" \
                --targets "Key=InstanceIds,Values=${instance_id}" \
                --parameters "commands=['stress-ng --vm 2 --vm-bytes 75% --timeout 300s &']" \
                --comment "Inject memory pressure"
            ;;
        "disk_pressure")
            # Create disk pressure
            aws ssm send-command \
                --document-name "AWS-RunShellScript" \
                --targets "Key=InstanceIds,Values=${instance_id}" \
                --parameters "commands=['dd if=/dev/zero of=/tmp/large_file bs=1M count=1024 &']" \
                --comment "Inject disk pressure"
            ;;
        "service_failure")
            # Simulate service crash
            aws ssm send-command \
                --document-name "AWS-RunShellScript" \
                --targets "Key=InstanceIds,Values=${instance_id}" \
                --parameters "commands=['systemctl stop minecraft && sleep 60 && systemctl start minecraft']" \
                --comment "Inject service failure"
            ;;
    esac
    
    # Wait for recovery period
    echo "Waiting ${RECOVERY_WAIT} seconds for recovery..."
    sleep "${RECOVERY_WAIT}"
    
    # Check system recovery
    check_recovery "$scenario" "$instance_id" || ((issues++))
    
    return $issues
}

check_recovery() {
    local scenario=$1
    local instance_id=$2
    
    echo "Checking recovery for: ${scenario}"
    
    # Get CloudWatch metrics for the recovery period
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ")
    
    case $scenario in
        "network_partition")
            # Check network connectivity recovery
            aws cloudwatch get-metric-statistics \
                --namespace "Minecraft" \
                --metric-name "NetworkConnectivity" \
                --start-time "$start_time" \
                --end-time "$end_time" \
                --period 60 \
                --statistics Average \
                | grep -q '"Average": 1' || return 1
            ;;
        "cpu_stress")
            # Check CPU utilization recovery
            aws cloudwatch get-metric-statistics \
                --namespace "Minecraft" \
                --metric-name "CPUUtilization" \
                --start-time "$start_time" \
                --end-time "$end_time" \
                --period 60 \
                --statistics Average \
                | grep -q '"Average": [0-9]\{1,2\}' || return 1
            ;;
        "memory_pressure")
            # Check memory recovery
            aws cloudwatch get-metric-statistics \
                --namespace "Minecraft" \
                --metric-name "MemoryUtilization" \
                --start-time "$start_time" \
                --end-time "$end_time" \
                --period 60 \
                --statistics Average \
                | grep -q '"Average": [0-9]\{1,2\}' || return 1
            ;;
        "disk_pressure")
            # Check disk space recovery
            aws cloudwatch get-metric-statistics \
                --namespace "Minecraft" \
                --metric-name "DiskUtilization" \
                --start-time "$start_time" \
                --end-time "$end_time" \
                --period 60 \
                --statistics Average \
                | grep -q '"Average": [0-9]\{1,2\}' || return 1
            ;;
        "service_failure")
            # Check service status
            aws ssm send-command \
                --document-name "AWS-RunShellScript" \
                --targets "Key=InstanceIds,Values=${instance_id}" \
                --parameters "commands=['systemctl is-active minecraft']" \
                | grep -q "active" || return 1
            ;;
    esac
    
    return 0
}

cleanup_chaos() {
    local instance_id=$1
    
    echo "Cleaning up chaos experiments..."
    
    # Remove network constraints
    aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --targets "Key=InstanceIds,Values=${instance_id}" \
        --parameters "commands=['tc qdisc del dev eth0 root 2>/dev/null || true']"
    
    # Stop stress tests
    aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --targets "Key=InstanceIds,Values=${instance_id}" \
        --parameters "commands=['pkill stress-ng 2>/dev/null || true']"
    
    # Remove test files
    aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --targets "Key=InstanceIds,Values=${instance_id}" \
        --parameters "commands=['rm -f /tmp/large_file']"
    
    # Ensure service is running
    aws ssm send-command \
        --document-name "AWS-RunShellScript" \
        --targets "Key=InstanceIds,Values=${instance_id}" \
        --parameters "commands=['systemctl start minecraft']"
}

generate_chaos_report() {
    local scenario=$1
    local success=$2
    
    echo "## Chaos Test Results - ${scenario}" >> "chaos_report.md"
    echo "Test Time: $(date '+%Y-%m-%d %H:%M:%S')" >> "chaos_report.md"
    echo "Recovery Status: $([[ $success -eq 0 ]] && echo 'Successful' || echo 'Failed')" >> "chaos_report.md"
    echo "" >> "chaos_report.md"
    
    # Add metric data
    echo "### System Metrics During Test" >> "chaos_report.md"
    for metric in CPUUtilization MemoryUtilization DiskUtilization NetworkConnectivity; do
        aws cloudwatch get-metric-statistics \
            --namespace "Minecraft" \
            --metric-name "$metric" \
            --start-time "$(date -u -d '-10 minutes' +"%Y-%m-%dT%H:%M:%SZ")" \
            --end-time "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --period 60 \
            --statistics Average Maximum \
            | jq -r --arg metric "$metric" \
                '.Datapoints[] | "- \($metric) at " + (.Timestamp) + ": Avg=" + (.Average|tostring) + "%, Max=" + (.Maximum|tostring) + "%"' \
            >> "chaos_report.md"
    done
    echo "" >> "chaos_report.md"
}

run_chaos_tests() {
    local total_issues=0
    
    echo "Starting chaos test suite..."
    echo "==========================="
    
    # Get instance ID
    local instance_id=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=minecraft-*" \
        --query "Reservations[].Instances[?State.Name=='running'][].InstanceId" \
        --output text)
    
    if [ -z "$instance_id" ]; then
        echo "No running Minecraft instance found"
        return 1
    fi
    
    # Initialize report
    echo "# Minecraft Server Chaos Test Report" > "chaos_report.md"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "chaos_report.md"
    echo "" >> "chaos_report.md"
    
    # Run each chaos scenario
    for scenario in "${!CHAOS_SCENARIOS[@]}"; do
        echo -e "\nExecuting chaos scenario: ${scenario}"
        echo "Description: ${CHAOS_SCENARIOS[$scenario]}"
        
        if ! inject_failure "$scenario" "$instance_id"; then
            ((total_issues++))
        fi
        
        generate_chaos_report "$scenario" $?
        
        # Cleanup after each scenario
        cleanup_chaos "$instance_id"
        
        # Wait between scenarios
        sleep 60
    done
    
    echo "==========================="
    echo "Chaos Test Summary:"
    echo "Total scenarios: ${#CHAOS_SCENARIOS[@]}"
    echo "Failed recoveries: ${total_issues}"
    
    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}All chaos tests passed!${NC}"
        return 0
    else
        echo -e "${YELLOW}Chaos tests completed with failures${NC}"
        return 1
    fi
}

main() {
    # Run chaos tests
    if ! run_chaos_tests; then
        echo "Chaos testing revealed resilience issues"
        exit 1
    fi
}