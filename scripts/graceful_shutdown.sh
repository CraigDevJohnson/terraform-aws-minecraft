#!/bin/bash

# Configuration
BACKUP_BEFORE_SHUTDOWN=true
GRACE_PERIOD=300  # 5 minutes
MC_SERVICE="minecraft"
MC_ROOT="${mc_root:-/home/minecraft}"

# Function to check if players are online
check_players() {
    local count=$(grep -c "Player connected" "$MC_ROOT/logs/latest.log" 2>/dev/null || echo "0")
    local disconnects=$(grep -c "Player disconnected" "$MC_ROOT/logs/latest.log" 2>/dev/null || echo "0")
    echo $((count - disconnects))
}

# Notify players of shutdown
notify_players() {
    local time=$1
    /usr/bin/screen -S minecraft -p 0 -X stuff "say Server shutting down in $time seconds^M"
}

# Perform backup
do_backup() {
    systemctl start minecraft-backup.service
    # Wait for backup to complete
    timeout 300 systemctl status minecraft-backup.service --no-pager
}

# Main shutdown sequence
main() {
    # Check if server is running
    if ! systemctl is-active --quiet $MC_SERVICE; then
        echo "Minecraft server is not running"
        exit 0
    fi

    # Check for players
    local players=$(check_players)
    if [ "$players" -gt 0 ]; then
        echo "Players still online. Starting grace period..."
        notify_players $GRACE_PERIOD
        sleep $GRACE_PERIOD
    fi

    # Final player check
    players=$(check_players)
    if [ "$players" -gt 0 ]; then
        echo "Players still online after grace period. Proceeding with shutdown anyway."
    fi

    # Stop minecraft service
    echo "Stopping Minecraft server..."
    systemctl stop $MC_SERVICE

    # Perform backup if enabled
    if [ "$BACKUP_BEFORE_SHUTDOWN" = true ]; then
        echo "Performing final backup..."
        do_backup
    fi

    # Update server status in SSM
    aws ssm put-parameter \
        --name "/minecraft/status/last-shutdown" \
        --value "$(date +%s)" \
        --type "String" \
        --overwrite

    echo "Shutdown complete"
}

main