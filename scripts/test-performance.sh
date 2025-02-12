#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Performance test configuration
DURATION=300  # 5 minutes
PLAYER_COUNT=5
TPS_THRESHOLD=18
LATENCY_THRESHOLD=100
MEMORY_THRESHOLD=85

# Test scenarios
declare -A TEST_SCENARIOS=(
    ["baseline"]="Normal operation, no load"
    ["player_load"]="Maximum player count"
    ["world_gen"]="New chunk generation"
    ["combat"]="Player combat scenarios"
    ["redstone"]="Redstone automation"
)

test_server_performance() {
    local scenario=$1
    local duration=$2
    local issues=0
    
    echo "Running performance test: ${scenario}"
    echo "Duration: ${duration} seconds"
    
    # Start metrics collection
    aws cloudwatch get-metric-statistics \
        --namespace "Minecraft" \
        --metric-name "TPS" \
        --start-time $(date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ") \
        --end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
        --period 60 \
        --statistics Average Minimum \
        > "metrics_${scenario}_start.json"
        
    # Run specific scenario
    case $scenario in
        "baseline")
            # Just monitor normal operation
            sleep "$duration"
            ;;
        "player_load")
            # Simulate maximum player connections
            for i in $(seq 1 $PLAYER_COUNT); do
                aws ssm send-command \
                    --document-name "Minecraft-SimulatePlayer" \
                    --targets "Key=tag:Name,Values=minecraft-*" \
                    --parameters "PlayerNumber=$i"
            done
            sleep "$duration"
            ;;
        "world_gen")
            # Trigger new chunk generation
            aws ssm send-command \
                --document-name "Minecraft-TeleportPlayers" \
                --targets "Key=tag:Name,Values=minecraft-*" \
                --parameters "Distance=1000"
            sleep "$duration"
            ;;
        "combat")
            # Simulate combat scenarios
            aws ssm send-command \
                --document-name "Minecraft-SimulateCombat" \
                --targets "Key=tag:Name,Values=minecraft-*"
            sleep "$duration"
            ;;
        "redstone")
            # Activate redstone test contraptions
            aws ssm send-command \
                --document-name "Minecraft-ActivateRedstone" \
                --targets "Key=tag:Name,Values=minecraft-*"
            sleep "$duration"
            ;;
    esac
    
    # Collect end metrics
    aws cloudwatch get-metric-statistics \
        --namespace "Minecraft" \
        --metric-name "TPS" \
        --start-time $(date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ") \
        --end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
        --period 60 \
        --statistics Average Minimum \
        > "metrics_${scenario}_end.json"
        
    # Analyze results
    local avg_tps=$(jq -r '.Datapoints[].Average' "metrics_${scenario}_end.json" | awk '{ sum += $1 } END { print sum/NR }')
    local min_tps=$(jq -r '.Datapoints[].Minimum' "metrics_${scenario}_end.json" | sort -n | head -n1)
    
    echo "Results for ${scenario}:"
    echo "Average TPS: ${avg_tps}"
    echo "Minimum TPS: ${min_tps}"
    
    if (( $(echo "$min_tps < $TPS_THRESHOLD" | bc -l) )); then
        echo -e "${YELLOW}WARNING: TPS dropped below threshold${NC}"
        ((issues++))
    fi
    
    # Check memory usage
    local memory_usage=$(aws cloudwatch get-metric-statistics \
        --namespace "Minecraft" \
        --metric-name "MemoryUtilization" \
        --start-time $(date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ") \
        --end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
        --period 60 \
        --statistics Maximum \
        --query 'Datapoints[0].Maximum' \
        --output text)
        
    if (( $(echo "$memory_usage > $MEMORY_THRESHOLD" | bc -l) )); then
        echo -e "${YELLOW}WARNING: Memory usage exceeded threshold${NC}"
        ((issues++))
    fi
    
    return $issues
}

generate_performance_report() {
    local scenario=$1
    
    echo "## Performance Test Results - ${scenario}" >> "performance_report.md"
    echo "Test Duration: ${DURATION} seconds" >> "performance_report.md"
    echo "" >> "performance_report.md"
    
    # Add TPS graph data
    echo "### TPS Over Time" >> "performance_report.md"
    jq -r '.Datapoints[] | [.Timestamp, .Average] | @tsv' "metrics_${scenario}_end.json" | \
        sort | \
        awk '{print "- " $1 ": " $2}' >> "performance_report.md"
    echo "" >> "performance_report.md"
    
    # Add memory usage data
    echo "### Memory Usage" >> "performance_report.md"
    aws cloudwatch get-metric-statistics \
        --namespace "Minecraft" \
        --metric-name "MemoryUtilization" \
        --start-time $(date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ") \
        --end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
        --period 60 \
        --statistics Average Maximum \
        | jq -r '.Datapoints[] | "- " + (.Timestamp) + ": " + (.Average | tostring) + "% (Max: " + (.Maximum | tostring) + "%)"' \
        >> "performance_report.md"
    echo "" >> "performance_report.md"
}

run_performance_tests() {
    local total_issues=0
    
    echo "Starting performance test suite..."
    echo "================================="
    
    # Initialize report
    echo "# Minecraft Server Performance Test Report" > "performance_report.md"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "performance_report.md"
    echo "" >> "performance_report.md"
    
    # Run each test scenario
    for scenario in "${!TEST_SCENARIOS[@]}"; do
        echo -e "\nTesting scenario: ${scenario}"
        echo "Description: ${TEST_SCENARIOS[$scenario]}"
        
        if ! test_server_performance "$scenario" "$DURATION"; then
            ((total_issues++))
        fi
        
        generate_performance_report "$scenario"
    done
    
    echo "================================="
    echo "Performance Test Summary:"
    echo "Total scenarios tested: ${#TEST_SCENARIOS[@]}"
    echo "Scenarios with issues: ${total_issues}"
    
    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}All performance tests passed!${NC}"
        return 0
    else
        echo -e "${YELLOW}Performance tests completed with warnings${NC}"
        return 1
    fi
}

cleanup() {
    # Clean up test artifacts
    rm -f metrics_*.json
    
    # Stop any running test scenarios
    aws ssm send-command \
        --document-name "Minecraft-StopTests" \
        --targets "Key=tag:Name,Values=minecraft-*" || true
}

main() {
    # Ensure cleanup runs on exit
    trap cleanup EXIT
    
    # Run performance tests
    run_performance_tests
}