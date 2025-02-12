#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Required metrics for different components
declare -A REQUIRED_METRICS=(
    ["core"]="CPUUtilization MemoryUtilization NetworkPacketsIn NetworkPacketsOut"
    ["minecraft"]="PlayerCount TPS MSPTAverage ActivePlayers"
    ["disk"]="DiskUsage DiskIOPS DiskThroughput"
    ["backup"]="BackupSize BackupDuration BackupSuccess"
    ["network"]="NetworkLatency PacketLoss ConnectionCount"
)

# Required alarms
declare -A REQUIRED_ALARMS=(
    ["performance"]="HighCPUUtilization LowMemoryAvailable HighDiskUsage"
    ["minecraft"]="LowTPS HighMSPT ServerUnreachable"
    ["backup"]="BackupFailure RestoreFailure BackupValidationError"
    ["security"]="UnauthorizedAccess FailedLoginAttempts WAFBlocks"
)

check_cloudwatch_metrics() {
    local component=$1
    local issues=0
    
    echo "Checking ${component} metrics..."
    
    # Check if metrics are defined in monitoring.tf
    for metric in ${REQUIRED_METRICS[$component]}; do
        if ! grep -q "metric_name.*${metric}" monitoring.tf; then
            echo -e "${YELLOW}WARNING: Missing metric: ${metric}${NC}"
            ((issues++))
        fi
    done
    
    return $issues
}

check_cloudwatch_alarms() {
    local component=$1
    local issues=0
    
    echo "Checking ${component} alarms..."
    
    # Check if alarms are defined in monitoring.tf
    for alarm in ${REQUIRED_ALARMS[$component]}; do
        if ! grep -q "alarm_name.*${alarm}" monitoring.tf; then
            echo -e "${YELLOW}WARNING: Missing alarm: ${alarm}${NC}"
            ((issues++))
        fi
    done
    
    return $issues
}

check_dashboard_configuration() {
    local issues=0
    
    echo "Checking CloudWatch dashboard configuration..."
    
    # Check if dashboard is defined
    if ! grep -q "aws_cloudwatch_dashboard" monitoring.tf; then
        echo -e "${YELLOW}WARNING: No CloudWatch dashboard defined${NC}"
        ((issues++))
    fi
    
    # Check if all required widgets are present
    for component in "${!REQUIRED_METRICS[@]}"; do
        if ! grep -q "${component,,}_widget" monitoring.tf; then
            echo -e "${YELLOW}WARNING: Missing dashboard widget for: ${component}${NC}"
            ((issues++))
        fi
    done
    
    return $issues
}

check_log_groups() {
    local issues=0
    
    echo "Checking CloudWatch log groups..."
    
    # Required log groups
    local required_logs=(
        "/minecraft/server"
        "/minecraft/backup"
        "/minecraft/security"
        "/minecraft/performance"
    )
    
    for log in "${required_logs[@]}"; do
        if ! grep -q "log_group_name.*${log}" monitoring.tf; then
            echo -e "${YELLOW}WARNING: Missing log group: ${log}${NC}"
            ((issues++))
        fi
    done
    
    return $issues
}

check_metric_filters() {
    local issues=0
    
    echo "Checking CloudWatch metric filters..."
    
    # Required metric filters
    local required_filters=(
        "ErrorCount"
        "WarningCount"
        "PlayerLoginCount"
        "BackupStatus"
    )
    
    for filter in "${required_filters[@]}"; do
        if ! grep -q "metric_transformation.*${filter}" monitoring.tf; then
            echo -e "${YELLOW}WARNING: Missing metric filter: ${filter}${NC}"
            ((issues++))
        fi
    done
    
    return $issues
}

validate_monitoring_configuration() {
    local total_issues=0
    
    echo "Running monitoring validation checks..."
    echo "======================================"
    
    # Check metrics for each component
    for component in "${!REQUIRED_METRICS[@]}"; do
        if ! check_cloudwatch_metrics "$component"; then
            ((total_issues++))
        fi
    done
    
    # Check alarms for each component
    for component in "${!REQUIRED_ALARMS[@]}"; do
        if ! check_cloudwatch_alarms "$component"; then
            ((total_issues++))
        fi
    done
    
    # Check dashboard configuration
    if ! check_dashboard_configuration; then
        ((total_issues++))
    fi
    
    # Check log groups
    if ! check_log_groups; then
        ((total_issues++))
    fi
    
    # Check metric filters
    if ! check_metric_filters; then
        ((total_issues++))
    fi
    
    echo "======================================"
    echo "Monitoring Validation Summary:"
    echo "Total issues found: ${total_issues}"
    
    if [ $total_issues -eq 0 ]; then
        echo -e "${GREEN}All monitoring checks passed!${NC}"
        return 0
    else
        echo -e "${YELLOW}Monitoring checks completed with warnings${NC}"
        return 1
    fi
}

# Execute monitoring validation
validate_monitoring_configuration