#!/bin/bash

# Configuration
VOLUME_ID=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)" "Name=attachment.device,Values=/dev/xvdf" --query "Volumes[0].VolumeId" --output text)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

create_snapshot() {
    local description="$1"
    aws ec2 create-snapshot \
        --volume-id "$VOLUME_ID" \
        --description "$description" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=minecraft-critical-op},{Key=InstanceId,Value=$INSTANCE_ID}]" \
        --region "$REGION"
}

wait_for_snapshot() {
    local snapshot_id="$1"
    while true; do
        status=$(aws ec2 describe-snapshots --snapshot-ids "$snapshot_id" --query 'Snapshots[0].State' --output text)
        if [ "$status" = "completed" ]; then
            break
        fi
        sleep 10
    done
}

case "$1" in
    pre-update)
        create_snapshot "Pre-update snapshot"
        ;;
    post-update)
        create_snapshot "Post-update snapshot"
        ;;
    pre-maintenance)
        create_snapshot "Pre-maintenance snapshot"
        ;;
    post-maintenance)
        create_snapshot "Post-maintenance snapshot"
        ;;
    *)
        echo "Usage: $0 {pre-update|post-update|pre-maintenance|post-maintenance}"
        exit 1
        ;;
esac