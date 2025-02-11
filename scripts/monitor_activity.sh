#!/bin/bash

# Configuration
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
MC_ROOT="${mc_root:-/home/minecraft}"
CHECK_INTERVAL=300  # 5 minutes
INACTIVE_THRESHOLD=1800  # 30 minutes
MIN_PLAYERS=1

# AWS CLI with region
AWS="aws --region $REGION"

check_active_hours() {
    current_hour=$(date +%H)
    start_hour=$($AWS ssm get-parameter --name "/minecraft/${INSTANCE_ID}/active-hours-start" --query "Parameter.Value" --output text)
    end_hour=$($AWS ssm get-parameter --name "/minecraft/${INSTANCE_ID}/active-hours-end" --query "Parameter.Value" --output text)
    
    if [ $current_hour -ge $start_hour ] && [ $current_hour -lt $end_hour ]; then
        return 0
    else
        return 1
    fi
}

get_player_count() {
    local count=0
    if [ -f "$MC_ROOT/logs/latest.log" ]; then
        local connected=$(grep -c "Player connected" "$MC_ROOT/logs/latest.log")
        local disconnected=$(grep -c "Player disconnected" "$MC_ROOT/logs/latest.log")
        count=$((connected - disconnected))
    fi
    echo $count
}

update_cloudwatch_metrics() {
    local player_count=$1
    $AWS cloudwatch put-metric-data \
        --namespace MinecraftServer \
        --metric-name PlayerCount \
        --value $player_count \
        --dimensions InstanceId=$INSTANCE_ID

    # Update last activity timestamp if players are present
    if [ $player_count -gt 0 ]; then
        $AWS ssm put-parameter \
            --name "/minecraft/${INSTANCE_ID}/last-activity" \
            --value "$(date +%s)" \
            --type String \
            --overwrite
    fi
}

check_inactivity() {
    local last_activity
    last_activity=$($AWS ssm get-parameter \
        --name "/minecraft/${INSTANCE_ID}/last-activity" \
        --query "Parameter.Value" \
        --output text)

    local current_time=$(date +%s)
    local time_diff=$((current_time - last_activity))

    if [ $time_diff -gt $INACTIVE_THRESHOLD ]; then
        return 0
    else
        return 1
    fi
}

initiate_shutdown() {
    logger "Initiating Minecraft server shutdown due to inactivity"
    /usr/local/bin/graceful-shutdown.sh
}

main() {
    while true; do
        player_count=$(get_player_count)
        update_cloudwatch_metrics $player_count

        if ! check_active_hours; then
            if [ $player_count -eq 0 ]; then
                if check_inactivity; then
                    logger "No players and outside active hours. Server idle for too long."
                    initiate_shutdown
                    break
                fi
            fi
        fi

        sleep $CHECK_INTERVAL
    done
}

main