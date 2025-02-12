#!/bin/bash -e

# Enable strict error handling
set -euo pipefail
IFS=$'\n\t'

# Configure logging
exec 1> >(logger -s -t $(basename $0)) 2>&1

# Function to log messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to handle errors
handle_error() {
    local exit_code=$?
    log "Error occurred in script at line: ${1} with exit code: ${exit_code}"
    # Notify via CloudWatch
    aws cloudwatch put-metric-data --namespace Minecraft --metric-name ServerSetupError --value 1 --unit Count
    exit ${exit_code}
}

# Set error handler
trap 'handle_error ${LINENO}' ERR

# System setup based on OS detection
setup_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log "Setting up system for ${NAME}"
        case $ID in
            "amzn")
                dnf update -y
                dnf install -y unzip jq wget curl amazon-cloudwatch-agent htop screen
                # Performance optimizations for Amazon Linux
                amazon-linux-extras install -y epel
                yum install -y sysstat
                
                # Enable performance improvements
                grubby --update-kernel=ALL --args="transparent_hugepage=always"
                echo "net.ipv4.tcp_tw_reuse=1" >> /etc/sysctl.conf
                echo "fs.file-max=100000" >> /etc/sysctl.conf
                echo "vm.swappiness=10" >> /etc/sysctl.conf
                ;;
            "ubuntu")
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get -y upgrade
                apt-get -y install unzip jq wget curl htop screen sysstat

                # Install CloudWatch agent for Ubuntu
                wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
                dpkg -i -E ./amazon-cloudwatch-agent.deb
                rm amazon-cloudwatch-agent.deb

                # Ubuntu-specific optimizations
                echo "transparent_hugepage=always" >> /etc/default/grub
                update-grub
                echo "fs.file-max = 100000" >> /etc/sysctl.conf
                echo "vm.swappiness = 10" >> /etc/sysctl.conf
                ;;
            *)
                log "Unsupported OS: ${NAME}"
                exit 1
                ;;
        esac

        # Apply system limits
        cat >> /etc/security/limits.conf << EOF
minecraft soft nofile 64000
minecraft hard nofile 64000
minecraft soft nproc 32000
minecraft hard nproc 32000
EOF

        # Reload sysctl settings
        sysctl -p
    else
        log "Cannot determine OS type"
        exit 1
    fi
}

# Install Java for Java edition server
setup_java_environment() {
    log "Setting up Java environment"
    
    case $ID in
        "amzn")
            # For Amazon Linux 2023
            dnf install -y java-17-amazon-corretto
            ;;
        "ubuntu")
            # For Ubuntu
            apt-get install -y openjdk-17-jre-headless
            ;;
    esac
    
    # Verify Java installation
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    log "Installed Java version: ${JAVA_VERSION}"
    
    # Report Java version to CloudWatch
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-name JavaVersion \
        --value "${JAVA_VERSION//./}" \
        --unit None
}

# Apply system performance optimizations
optimize_system() {
    log "Applying system optimizations"
    
    # Network optimizations
    cat >> /etc/sysctl.conf << EOF
# Network performance optimizations
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fin_timeout = 30
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 2000

# Memory optimizations
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2
EOF

    sysctl -p

    # I/O optimizations
    if [ -b /dev/xvdf ]; then
        log "Configuring EBS volume"
        mkfs -t ext4 /dev/xvdf
        mkdir -p ${mc_root}
        mount /dev/xvdf ${mc_root}
        echo "/dev/xvdf ${mc_root} ext4 defaults,noatime 0 2" >> /etc/fstab
    fi
}

# Setup minecraft user and permissions
setup_minecraft_user() {
    log "Setting up minecraft user"
    useradd -r -m -U -d ${mc_root} -s /bin/bash minecraft

    # Create required directories
    mkdir -p ${mc_root}/backups
    mkdir -p ${mc_root}/logs
    mkdir -p /etc/minecraft

    # Setup environment configuration
    cat > /etc/minecraft/server.env << ENV
mc_root=${mc_root}
mc_bucket=${mc_bucket}
mc_backup_freq=${mc_backup_freq}
server_edition=${server_edition}
mc_version=${mc_version}
ENV

    # Set proper permissions
    chown -R minecraft:minecraft ${mc_root}
    chmod 750 ${mc_root}
}

# Configure monitoring and alerts
setup_monitoring() {
    log "Configuring monitoring"
    
    # CloudWatch agent configuration with game-specific metrics
    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOL'
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
    },
    "metrics": {
        "namespace": "Minecraft",
        "metrics_collected": {
            "cpu": {
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_user",
                    "cpu_usage_system"
                ],
                "metrics_collection_interval": 60
            },
            "mem": {
                "measurement": [
                    "mem_used_percent",
                    "mem_available_percent",
                    "mem_total",
                    "mem_cached"
                ],
                "metrics_collection_interval": 60
            },
            "net": {
                "measurement": [
                    "bytes_sent",
                    "bytes_recv",
                    "packets_sent",
                    "packets_recv",
                    "drop_in",
                    "drop_out"
                ],
                "metrics_collection_interval": 30
            },
            "disk": {
                "measurement": [
                    "used_percent",
                    "inodes_free",
                    "write_bytes",
                    "read_bytes",
                    "writes",
                    "reads"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            }
        },
        "force_flush_interval": 30
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "${mc_root}/logs/latest.log",
                        "log_group_name": "/minecraft/server/logs",
                        "log_stream_name": "{instance_id}",
                        "timezone": "UTC"
                    }
                ]
            }
        }
    }
}
EOL

    systemctl enable amazon-cloudwatch-agent
    systemctl start amazon-cloudwatch-agent
}

# Configure backup system
setup_backup_system() {
    log "Setting up backup system"
    
    # Create backup script with differential backup support
    cat > ${mc_root}/backup.sh << 'BACKUP'
#!/bin/bash
source /etc/minecraft/server.env

# Function to calculate backup size
calculate_backup_size() {
    du -sb "$1" | cut -f1
}

# Function to log backup metrics
log_backup_metrics() {
    local size=$1
    local duration=$2
    local type=$3
    
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-data \
        "MetricName=BackupSize,Value=${size},Unit=Bytes,Dimensions=[{Name=BackupType,Value=${type}}]" \
        "MetricName=BackupDuration,Value=${duration},Unit=Seconds,Dimensions=[{Name=BackupType,Value=${type}}]"
}

# Perform backup
START_TIME=$(date +%s)
aws s3 sync ${mc_root} s3://${mc_bucket} \
    --delete \
    --exclude "*.tmp" \
    --exclude "*.log" \
    --storage-class STANDARD_IA

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
SIZE=$(calculate_backup_size ${mc_root})

log_backup_metrics $SIZE $DURATION "Differential"
BACKUP

    chmod +x ${mc_root}/backup.sh
    chown minecraft:minecraft ${mc_root}/backup.sh

    # Setup backup service and timer
    cat > /etc/systemd/system/minecraft-backup.service << 'BACKUPSVC'
[Unit]
Description=Minecraft Server Backup Service
After=minecraft.service

[Service]
Type=oneshot
User=minecraft
ExecStart=${mc_root}/backup.sh
TimeoutStartSec=3600
BACKUPSVC

    cat > /etc/systemd/system/minecraft-backup.timer << TIMER
[Unit]
Description=Minecraft Server Backup Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=${mc_backup_freq}m

[Install]
WantedBy=timers.target
TIMER

    systemctl enable minecraft-backup.timer
}

# Download and configure Bedrock server
setup_bedrock_server() {
    log "Setting up Bedrock server"
    cd ${mc_root}
    
    # Function to get latest Bedrock server URL
    get_bedrock_url() {
        curl -s https://www.minecraft.net/en-us/download/server/bedrock | \
        grep -o 'https://minecraft.azureedge.net/bin-linux/[^"]*'
    }

    # Download and install server
    DOWNLOAD_URL=$(get_bedrock_url)
    if [ -z "$DOWNLOAD_URL" ]; then
        log "Failed to get Bedrock server download URL"
        aws cloudwatch put-metric-data --namespace Minecraft --metric-name DownloadError --value 1 --unit Count
        exit 1
    }

    wget -O bedrock-server.zip "$DOWNLOAD_URL"
    unzip -o bedrock-server.zip
    rm bedrock-server.zip
    chmod +x bedrock_server

    # Configure server properties
    cat > server.properties << PROP
server-name=Minecraft AWS Server
gamemode=survival
difficulty=normal
allow-cheats=false
max-players=5
online-mode=true
white-list=false
server-port=${mc_port}
player-idle-timeout=30
view-distance=10
tick-distance=4
max-threads=2
content-log-file-enabled=true
compression-threshold=1
server-authoritative-movement=server-auth
player-movement-score-threshold=20
player-movement-action-direction-threshold=0.85
PROP

    # Create server startup script
    cat > start_server.sh << 'BEDROCK'
#!/bin/bash
cd ${mc_root}
LD_LIBRARY_PATH=. ./bedrock_server
BEDROCK

    chmod +x start_server.sh
}

# Download and configure Java server
setup_java_server() {
    log "Setting up Java server"
    cd ${mc_root}
    
    # Get server version and download URL
    VERSION_MANIFEST="https://launchermeta.mojang.com/mc/game/version_manifest.json"
    if [ "${mc_version}" = "latest" ]; then
        MC_VERSION=$(curl -s $VERSION_MANIFEST | jq -r '.versions[0].id')
    else
        MC_VERSION="${mc_version}"
    fi
    
    VERSIONS_URL=$(curl -s $VERSION_MANIFEST | jq -r --arg VER "$MC_VERSION" '.versions[] | select(.id==$VER) | .url')
    SERVER_URL=$(curl -s $VERSIONS_URL | jq -r '.downloads.server.url')
    
    wget -O server.jar "$SERVER_URL"

    # Create server properties with optimized settings
    cat > server.properties << PROP
server-port=${mc_port}
gamemode=survival
difficulty=normal
max-players=5
view-distance=8
simulation-distance=6
network-compression-threshold=256
prevent-proxy-connections=false
max-tick-time=60000
enable-jmx-monitoring=true
sync-chunk-writes=true
enable-status=true
online-mode=true
allow-flight=false
broadcast-rcon-to-ops=true
spawn-protection=16
max-world-size=29999984
resource-pack-prompt=
allow-nether=true
enable-command-block=false
player-idle-timeout=30
force-gamemode=false
white-list=false
spawn-monsters=true
enforce-whitelist=false
spawn-npcs=true
spawn-animals=true
generate-structures=true
max-build-height=256
text-filtering-config=
use-native-transport=true
rate-limit=0
view-distance=10
PROP

    # Create optimized startup script
    cat > start_server.sh << 'JAVA'
#!/bin/bash
cd ${mc_root}
java -Xms${java_ms_mem} -Xmx${java_mx_mem} \
    -XX:+UseG1GC \
    -XX:+ParallelRefProcEnabled \
    -XX:MaxGCPauseMillis=200 \
    -XX:+UnlockExperimentalVMOptions \
    -XX:+DisableExplicitGC \
    -XX:+AlwaysPreTouch \
    -XX:G1HeapWastePercent=5 \
    -XX:G1MixedGCCountTarget=4 \
    -XX:G1MixedGCLiveThresholdPercent=90 \
    -XX:G1RSetUpdatingPauseTimePercent=5 \
    -XX:SurvivorRatio=32 \
    -XX:+PerfDisableSharedMem \
    -XX:MaxTenuringThreshold=1 \
    -XX:G1NewSizePercent=30 \
    -XX:G1MaxNewSizePercent=40 \
    -XX:G1HeapRegionSize=8M \
    -XX:G1ReservePercent=20 \
    -XX:InitiatingHeapOccupancyPercent=15 \
    -Dusing.aikars.flags=https://mcflags.emc.gs \
    -Daikars.new.flags=true \
    -jar server.jar nogui
JAVA

    chmod +x start_server.sh
}

# Create systemd service for the server
setup_server_service() {
    log "Setting up server service"
    
    # Create systemd service
    cat > /etc/systemd/system/minecraft.service << SERVICE
[Unit]
Description=Minecraft Server
After=network.target

[Service]
Type=simple
User=minecraft
WorkingDirectory=${mc_root}
ExecStart=${mc_root}/start_server.sh
Restart=on-failure
RestartSec=30
TimeoutStartSec=300
ExecStop=/usr/local/bin/graceful-shutdown.sh
StandardOutput=append:/var/log/minecraft/server.log
StandardError=append:/var/log/minecraft/error.log

[Install]
WantedBy=multi-user.target
SERVICE

    # Create graceful shutdown script
    cat > /usr/local/bin/graceful-shutdown.sh << 'SHUTDOWN'
#!/bin/bash
source /etc/minecraft/server.env

# Trigger final backup
${mc_root}/backup.sh

# Stop the server gracefully based on edition
if [ "${server_edition}" = "bedrock" ]; then
    screen -S minecraft -X stuff "stop\n"
else
    screen -S minecraft -X stuff "save-all\nstop\n"
fi

# Wait for server to stop (max 60 seconds)
for i in {1..60}; do
    if ! pgrep -f "(bedrock_server|server.jar)" > /dev/null; then
        exit 0
    fi
    sleep 1
done

# Force stop if necessary
pkill -f "(bedrock_server|server.jar)"
SHUTDOWN

    chmod +x /usr/local/bin/graceful-shutdown.sh
    
    # Create log directory
    mkdir -p /var/log/minecraft
    chown minecraft:minecraft /var/log/minecraft
}

# Setup systemd service recovery
setup_service_recovery() {
    log "Configuring service recovery settings"

    # Update minecraft.service with recovery settings
    sed -i '/\[Service\]/a StartLimitIntervalSec=300\nStartLimitBurst=3\nRestartSec=30\nRestart=on-failure' /etc/systemd/system/minecraft.service

    # Create service recovery script
    cat > /usr/local/bin/minecraft-recovery.sh << 'RECOVERY'
#!/bin/bash
source /etc/minecraft/server.env

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
RECOVERY_LOG="/var/log/minecraft/recovery.log"

echo "[$TIMESTAMP] Service recovery triggered" >> $RECOVERY_LOG

# Check if process exists but is unresponsive
if pgrep -f "(bedrock_server|server.jar)" > /dev/null; then
    echo "[$TIMESTAMP] Server process found but potentially unresponsive" >> $RECOVERY_LOG
    
    # Try graceful shutdown first
    /usr/local/bin/graceful-shutdown.sh
    sleep 10
    
    # Force kill if still running
    if pgrep -f "(bedrock_server|server.jar)" > /dev/null; then
        pkill -9 -f "(bedrock_server|server.jar)"
        echo "[$TIMESTAMP] Forced process termination" >> $RECOVERY_LOG
    fi
fi

# Verify disk space
DISK_USAGE=$(df ${mc_root} | tail -1 | awk '{print $5}' | tr -d '%')
if [ "${DISK_USAGE}" -gt 90 ]; then
    echo "[$TIMESTAMP] Critical disk usage: ${DISK_USAGE}%" >> $RECOVERY_LOG
    
    # Clean old logs and temp files
    find ${mc_root}/logs -type f -mtime +7 -delete
    find ${mc_root} -name "*.tmp" -type f -delete
    
    # Notify via CloudWatch
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-name DiskSpaceCritical \
        --value 1 \
        --unit Count
fi

# Check and repair file permissions
find ${mc_root} ! -user minecraft -exec chown minecraft:minecraft {} +
find ${mc_root} -type d ! -perm 750 -exec chmod 750 {} +
find ${mc_root} -type f ! -perm 640 -exec chmod 640 {} +

# Report recovery attempt
aws cloudwatch put-metric-data \
    --namespace Minecraft \
    --metric-name ServiceRecoveryAttempt \
    --value 1 \
    --unit Count

echo "[$TIMESTAMP] Recovery procedure completed" >> $RECOVERY_LOG
RECOVERY

    chmod +x /usr/local/bin/minecraft-recovery.sh

    # Add recovery script to service
    sed -i '/\[Service\]/a ExecStartPre=/usr/local/bin/minecraft-recovery.sh' /etc/systemd/system/minecraft.service
}

# Setup performance monitoring
setup_performance_monitoring() {
    log "Setting up performance monitoring"
    
    # Create monitoring script
    cat > ${mc_root}/monitor_performance.sh << 'MONITOR'
#!/bin/bash
source /etc/minecraft/server.env

# Function to get player count
get_player_count() {
    if [ "${server_edition}" = "bedrock" ]; then
        # For Bedrock, parse the current_players file
        if [ -f "${mc_root}/current_players" ]; then
            cat "${mc_root}/current_players" | wc -l
        else
            echo "0"
        fi
    else
        # For Java, parse the logs
        grep -c "logged in with entity" "${mc_root}/logs/latest.log"
    fi
}

# Function to get TPS (Ticks Per Second)
get_tps() {
    if [ "${server_edition}" = "bedrock" ]; then
        # Bedrock server performance metrics
        grep "tick rate" "${mc_root}/logs/latest.log" | tail -n 1 | awk '{print $NF}'
    else
        # Java server performance metrics
        grep "tick rate" "${mc_root}/logs/latest.log" | tail -n 1 | awk '{print $NF}'
    fi
}

# Report metrics to CloudWatch
while true; do
    PLAYERS=$(get_player_count)
    TPS=$(get_tps)
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
    MEMORY_USAGE=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
    
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-data \
        "MetricName=PlayerCount,Value=${PLAYERS},Unit=Count" \
        "MetricName=TPS,Value=${TPS},Unit=Count" \
        "MetricName=CPUUsage,Value=${CPU_USAGE},Unit=Percent" \
        "MetricName=MemoryUsage,Value=${MEMORY_USAGE},Unit=Percent"
    
    # Check auto-shutdown conditions
    if [ "${enable_auto_shutdown}" = "true" ] && [ "${PLAYERS}" -eq "0" ]; then
        INACTIVE_TIME=$(($(date +%s) - $(stat -c %Y "${mc_root}/logs/latest.log")))
        if [ ${INACTIVE_TIME} -gt 1800 ]; then # 30 minutes
            log "No players for 30 minutes, initiating shutdown"
            /usr/local/bin/graceful-shutdown.sh
        fi
    fi
    
    sleep 60
done
MONITOR

    chmod +x ${mc_root}/monitor_performance.sh

    # Create systemd service for monitoring
    cat > /etc/systemd/system/minecraft-monitor.service << SERVICE
[Unit]
Description=Minecraft Server Performance Monitor
After=minecraft.service
Requires=minecraft.service

[Service]
Type=simple
User=minecraft
ExecStart=${mc_root}/monitor_performance.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl enable minecraft-monitor.service
}

# Setup health check endpoint
setup_health_check() {
    log "Setting up health check endpoint"
    
    cat > ${mc_root}/health_check.sh << 'HEALTH'
#!/bin/bash
source /etc/minecraft/server.env

# Check server process
if ! pgrep -f "${server_edition}" > /dev/null; then
    echo "Server process not running"
    exit 1
fi

# Check server responsiveness
if [ "${server_edition}" = "bedrock" ]; then
    # Bedrock uses UDP, check process responsiveness
    if ! ps aux | grep bedrock_server | grep -v grep > /dev/null; then
        echo "Bedrock server not responding"
        exit 1
    fi
else
    # Java edition TCP check
    if ! nc -z localhost ${mc_port}; then
        echo "Java server not responding"
        exit 1
    fi
fi

# Check disk space
DISK_USAGE=$(df ${mc_root} | tail -1 | awk '{print $5}' | tr -d '%')
if [ "${DISK_USAGE}" -gt 90 ]; then
    echo "Disk usage critical: ${DISK_USAGE}%"
    exit 1
fi

# All checks passed
echo "OK"
exit 0
HEALTH

    chmod +x ${mc_root}/health_check.sh

    # Setup systemd timer for regular health checks
    cat > /etc/systemd/system/minecraft-health.service << 'HEALTHSVC'
[Unit]
Description=Minecraft Server Health Check
After=minecraft.service

[Service]
Type=oneshot
User=minecraft
ExecStart=${mc_root}/health_check.sh
HEALTHSVC

    cat > /etc/systemd/system/minecraft-health.timer << 'HEALTHTIMER'
[Unit]
Description=Run Minecraft health check every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
HEALTHTIMER

    systemctl enable minecraft-health.timer
}

# Tune server performance based on instance type
tune_server_performance() {
    log "Tuning server performance"
    
    # Get instance type metadata
    INSTANCE_TYPE=$(curl -s http://169.254.169.254/latest/meta-data/instance-type)
    
    # Configure based on instance type
    case ${INSTANCE_TYPE} in
        t3a.small)
            # Conservative settings for t3a.small
            echo "view-distance=8" >> ${mc_root}/server.properties
            echo "simulation-distance=4" >> ${mc_root}/server.properties
            echo "max-players=5" >> ${mc_root}/server.properties
            ;;
        t3a.medium|t3a.large)
            # Balanced settings for medium instances
            echo "view-distance=10" >> ${mc_root}/server.properties
            echo "simulation-distance=6" >> ${mc_root}/server.properties
            echo "max-players=10" >> ${mc_root}/server.properties
            ;;
        *)
            # Default conservative settings
            echo "view-distance=8" >> ${mc_root}/server.properties
            echo "simulation-distance=4" >> ${mc_root}/server.properties
            echo "max-players=5" >> ${mc_root}/server.properties
            ;;
    esac
    
    # Report configuration to CloudWatch
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-data \
        "MetricName=InstanceType,Value=1,Unit=None,Dimensions=[{Name=Type,Value=${INSTANCE_TYPE}}]"
}

# Enhance backup validation
enhance_backup_validation() {
    log "Setting up enhanced backup validation"
    
    cat > ${mc_root}/validate_backup.sh << 'VALIDATE'
#!/bin/bash
source /etc/minecraft/server.env

validate_backup() {
    local backup_path="$1"
    local validation_errors=0
    
    # Check backup size
    local size=$(du -sb "${backup_path}" | cut -f1)
    if [ "${size}" -lt 1048576]; then
        log "Warning: Backup size is suspiciously small: ${size} bytes"
        ((validation_errors++))
    fi
    
    # Check world data integrity
    if [ "${server_edition}" = "bedrock" ]; then
        # Bedrock world files
        for file in worlds/*/level.dat worlds/*/level.dat_old worlds/*/db/*; do
            if [ ! -f "${backup_path}/${file}" ]; then
                log "Error: Missing critical file: ${file}"
                ((validation_errors++))
            fi
        done
    else
        # Java edition world files
        for file in world/level.dat world/level.dat_old world/data/*.dat; do
            if [ ! -f "${backup_path}/${file}" ]; then
                log "Error: Missing critical file: ${file}"
                ((validation_errors++))
            fi
        done
    fi
    
    # Check configuration files
    for file in server.properties permissions.json whitelist.json; do
        if [ ! -f "${backup_path}/${file}" ]; then
            log "Warning: Missing configuration file: ${file}"
            ((validation_errors++))
        fi
    done
    
    # Verify backup is readable
    if ! tar tf "${backup_path}/latest.tar.gz" &>/dev/null; then
        log "Error: Backup archive is corrupted"
        ((validation_errors++))
    fi
    
    # Report validation metrics with details
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-data \
        "MetricName=BackupValidationErrors,Value=${validation_errors},Unit=Count" \
        "MetricName=BackupSize,Value=${size},Unit=Bytes" \
        "MetricName=BackupValidation,Value=1,Unit=Count,Dimensions=[{Name=Status,Value=$([[ ${validation_errors} -eq 0 ]] && echo Success || echo Failure)}]"
    
    return ${validation_errors}
}

validate_backup "${mc_root}"
VALIDATE

    chmod +x ${mc_root}/validate_backup.sh
}

# Monitor server resource usage
setup_resource_monitoring() {
    log "Setting up resource monitoring"
    
    cat > ${mc_root}/monitor_resources.sh << 'MONITOR'
#!/bin/bash
source /etc/minecraft/server.env

# Monitor CPU credits for t3/t3a instances
monitor_cpu_credits() {
    if [[ $(curl -s http://169.254.169.254/latest/meta-data/instance-type) == t3* ]]; then
        CREDITS=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/EC2 \
            --metric-name CPUCreditBalance \
            --dimensions Name=InstanceId,Value=$(curl -s http://169.254.169.254/latest/meta-data/instance-id) \
            --start-time $(date -u +"%Y-%m-%dT%H:%M:%SZ" --date '5 minutes ago') \
            --end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ") \
            --period 300 \
            --statistics Average \
            --query "Datapoints[0].Average" \
            --output text)
        
        if [[ ${CREDITS%.*} -lt 20 ]]; then
            log "Warning: Low CPU credits: ${CREDITS}"
            aws cloudwatch put-metric-data \
                --namespace Minecraft \
                --metric-name LowCPUCredits \
                --value 1 \
                --unit Count
        fi
    fi
}

# Monitor process memory usage
monitor_memory() {
    local process_pattern
    if [ "${server_edition}" = "bedrock" ]; then
        process_pattern="bedrock_server"
    else
        process_pattern="java.*server.jar"
    fi
    
    MEMORY_USAGE=$(ps aux | grep -E "$process_pattern" | grep -v grep | awk '{print $6/1024}')
    
    if [ ! -z "$MEMORY_USAGE" ]; then
        aws cloudwatch put-metric-data \
            --namespace Minecraft \
            --metric-name ServerMemoryUsageMB \
            --value ${MEMORY_USAGE} \
            --unit Megabytes
            
        # Alert if memory usage is above 85%
        if [ "${server_edition}" = "java" ] && [ ${MEMORY_USAGE%.*} -gt $((${java_mx_mem%?} * 85 / 100)) ]; then
            log "Warning: High memory usage: ${MEMORY_USAGE}MB"
            /usr/local/bin/recover_server.sh memory
        fi
    fi
}

# Main monitoring loop
while true; do
    monitor_cpu_credits
    monitor_memory
    sleep 60
done
MONITOR

    chmod +x ${mc_root}/monitor_resources.sh
    
    # Create systemd service
    cat > /etc/systemd/system/minecraft-resources.service << SERVICE
[Unit]
Description=Minecraft Server Resource Monitor
After=minecraft.service
Requires=minecraft.service

[Service]
Type=simple
User=minecraft
ExecStart=${mc_root}/monitor_resources.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl enable minecraft-resources.service
}

# Setup automatic recovery procedures
setup_recovery_procedures() {
    log "Setting up recovery procedures"
    
    cat > /usr/local/bin/recover_server.sh << 'RECOVERY'
#!/bin/bash
source /etc/minecraft/server.env

recover_from_memory_issue() {
    log "Attempting memory recovery"
    
    # Save world data before recovery
    if [ "${server_edition}" = "bedrock" ]; then
        screen -S minecraft -X stuff "save hold\n"
        sleep 5
        screen -S minecraft -X stuff "save resume\n"
    else
        screen -S minecraft -X stuff "save-all\n"
    fi
    
    # Trigger emergency backup
    ${mc_root}/backup.sh
    
    # Restart the server
    systemctl restart minecraft
    
    # Report recovery attempt
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-name RecoveryAttempt \
        --value 1 \
        --unit Count \
        --dimensions Type=Memory
}

recover_from_crash() {
    log "Attempting crash recovery"
    
    # Check for crash dumps
    if [ "${server_edition}" = "bedrock" ]; then
        if [ -d "${mc_root}/crashes" ]; then
            # Archive crash reports
            tar -czf "${mc_root}/crashes/crash_$(date +%Y%m%d_%H%M%S).tar.gz" "${mc_root}/crashes/"*.txt
            aws s3 cp "${mc_root}/crashes/crash_*.tar.gz" "s3://${mc_bucket}/crashes/"
            rm -f "${mc_root}/crashes/"*.txt
        fi
    else
        if [ -d "${mc_root}/crash-reports" ]; then
            # Archive crash reports
            tar -czf "${mc_root}/crash-reports/crash_$(date +%Y%m%d_%H%M%S).tar.gz" "${mc_root}/crash-reports/"*.txt
            aws s3 cp "${mc_root}/crash-reports/crash_*.tar.gz" "s3://${mc_bucket}/crashes/"
            rm -f "${mc_root}/crash-reports/"*.txt
        fi
    fi
    
    # Attempt server restart
    systemctl restart minecraft
    
    # Report recovery attempt
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-name RecoveryAttempt \
        --value 1 \
        --unit Count \
        --dimensions Type=Crash
}

# Handle different recovery scenarios
case "$1" in
    "memory")
        recover_from_memory_issue
        ;;
    "crash")
        recover_from_crash
        ;;
    *)
        echo "Usage: $0 {memory|crash}"
        exit 1
        ;;
esac
RECOVERY

    chmod +x /usr/local/bin/recover_server.sh
}

# Setup status reporting
setup_status_reporting() {
    log "Setting up status reporting"
    
    cat > ${mc_root}/report_status.sh << 'STATUS'
#!/bin/bash
source /etc/minecraft/server.env

# Function to collect system metrics
collect_system_metrics() {
    local metrics="{}"
    
    # System metrics
    metrics=$(jq -n \
        --arg load "$(uptime | awk -F'load average:' '{print $2}')" \
        --arg disk "$(df -h ${mc_root} | tail -1 | awk '{print $5}')" \
        --arg mem "$(free -m | awk '/Mem:/ {printf("%.1f", $3/$2 * 100)}')" \
        --arg cpu "$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')" \
        '{
            load: $load,
            disk_usage: $disk,
            memory_usage: $mem,
            cpu_usage: $cpu
        }'
    )
    
    echo "${metrics}"
}

# Function to collect server metrics
collect_server_metrics() {
    local metrics="{}"
    local server_pid
    
    if [ "${server_edition}" = "bedrock" ]; then
        server_pid=$(pgrep -f "bedrock_server")
    else
        server_pid=$(pgrep -f "java.*server.jar")
    fi
    
    if [ ! -z "$server_pid" ]; then
        metrics=$(jq -n \
            --arg uptime "$(ps -o etimes= -p $server_pid)" \
            --arg mem "$(ps -o rss= -p $server_pid | awk '{print $1/1024}')" \
            --arg players "$(get_player_count)" \
            --arg tps "$(get_tps)" \
            '{
                server_uptime: $uptime,
                server_memory: $mem,
                player_count: $players,
                tps: $tps
            }'
        )
    fi
    
    echo "${metrics}"
}

# Main reporting loop
while true; do
    SYSTEM_METRICS=$(collect_system_metrics)
    SERVER_METRICS=$(collect_server_metrics)
    
    # Combine metrics
    STATUS=$(jq -n \
        --argjson sys "$SYSTEM_METRICS" \
        --argjson srv "$SERVER_METRICS" \
        --arg time "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg edition "${server_edition}" \
        '{
            timestamp: $time,
            edition: $edition,
            system: $sys,
            server: $srv
        }'
    )
    
    # Save status locally
    echo "$STATUS" > ${mc_root}/status.json
    
    # Upload to S3 for external monitoring
    aws s3 cp ${mc_root}/status.json s3://${mc_bucket}/status/current.json
    
    # Report key metrics to CloudWatch
    jq -r '.server | to_entries[] | .key + " " + .value' <<< "$SERVER_METRICS" | \
    while read -r key value; do
        aws cloudwatch put-metric-data \
            --namespace Minecraft \
            --metric-name "Server${key^}" \
            --value "$value" \
            --unit None
    done
    
    sleep 60
done
STATUS

    chmod +x ${mc_root}/report_status.sh
    
    # Create systemd service for status reporting
    cat > /etc/systemd/system/minecraft-status.service << SERVICE
[Unit]
Description=Minecraft Server Status Reporter
After=minecraft.service
Requires=minecraft.service

[Service]
Type=simple
User=minecraft
ExecStart=${mc_root}/report_status.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl enable minecraft-status.service
}

# Setup security hardening
setup_security_hardening() {
    log "Setting up security hardening"
    
    # Secure SSH configuration
    cat > /etc/ssh/sshd_config.d/minecraft.conf << 'SSH'
# Secure SSH configuration for Minecraft server
PermitRootLogin no
PasswordAuthentication no
AllowUsers minecraft
Protocol 2
LoginGraceTime 60
MaxAuthTries 3
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
SSH

    systemctl restart sshd

    # Set up fail2ban for SSH protection
    if command -v apt-get >/dev/null; then
        apt-get install -y fail2ban
    else
        dnf install -y fail2ban
    fi

    cat > /etc/fail2ban/jail.local << 'FAIL2BAN'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = %(sshd_log)s
maxretry = 3
FAIL2BAN

    systemctl enable fail2ban
    systemctl start fail2ban

    # Set up host-based firewall (using iptables or nftables)
    if command -v nft >/dev/null; then
        # Use nftables for newer systems
        cat > /etc/nftables.conf << 'NFT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow established connections
        ct state established,related accept
        
        # Allow loopback
        iifname lo accept
        
        # Allow SSH
        tcp dport ssh ct state new accept
        
        # Allow Minecraft port based on server edition
        $server_edition == "bedrock" ? udp dport $mc_port accept : tcp dport $mc_port accept
        
        # Allow ICMP
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFT
        systemctl enable nftables
        systemctl start nftables
    else
        # Use iptables for older systems
        # Flush existing rules
        iptables -F
        
        # Set default policies
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT
        
        # Allow established connections
        iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        
        # Allow loopback
        iptables -A INPUT -i lo -j ACCEPT
        
        # Allow SSH
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        
        # Allow Minecraft port based on server edition
        if [ "${server_edition}" = "bedrock" ]; then
            iptables -A INPUT -p udp --dport ${mc_port} -j ACCEPT
        else
            iptables -A INPUT -p tcp --dport ${mc_port} -j ACCEPT
        fi
        
        # Allow ICMP
        iptables -A INPUT -p icmp -j ACCEPT
        
        # Save rules
        if [ -f /etc/redhat-release ]; then
            service iptables save
        else
            iptables-save > /etc/iptables/rules.v4
        fi
    fi

    # Set secure file permissions
    chmod 750 ${mc_root}
    chmod 640 ${mc_root}/server.properties
    chmod 640 ${mc_root}/whitelist.json
    chmod 640 ${mc_root}/ops.json
    
    # Ensure all scripts are owned by minecraft user
    chown -R minecraft:minecraft ${mc_root}
    
    # Report security setup to CloudWatch
    aws cloudwatch put-metric-data \
        --namespace Minecraft \
        --metric-name SecurityHardening \
        --value 1 \
        --unit Count \
        --dimensions Status=Completed
}

# Setup security monitoring and audit logging
setup_security_monitoring() {
    log "Setting up security monitoring and audit logging"

    # Create security audit script
    cat > ${mc_root}/monitor_security.sh << 'SECURITY'
#!/bin/bash
source /etc/minecraft/server.env

# Monitor SSH attempts
monitor_ssh_attempts() {
    local failed_attempts=$(grep "Failed password" /var/log/auth.log | wc -l)
    local successful_logins=$(grep "Accepted publickey" /var/log/auth.log | wc -l)
    
    aws cloudwatch put-metric-data \
        --namespace Minecraft/Security \
        --metric-data \
        "MetricName=FailedSSHAttempts,Value=${failed_attempts},Unit=Count" \
        "MetricName=SuccessfulSSHLogins,Value=${successful_logins},Unit=Count"
}

# Monitor file integrity
check_file_integrity() {
    local changes=0
    if [ -f "${mc_root}/file_hashes.txt" ]; then
        changes=$(find ${mc_root} -type f -newer "${mc_root}/file_hashes.txt" | wc -l)
    fi
    
    # Update file hashes
    find ${mc_root} -type f -exec sha256sum {} \; > "${mc_root}/file_hashes.new"
    mv "${mc_root}/file_hashes.new" "${mc_root}/file_hashes.txt"
    
    aws cloudwatch put-metric-data \
        --namespace Minecraft/Security \
        --metric-name FileSystemChanges \
        --value ${changes} \
        --unit Count
}

# Monitor network connections
monitor_connections() {
    local concurrent_connections=$(netstat -an | grep :${mc_port} | wc -l)
    local unique_ips=$(netstat -an | grep :${mc_port} | awk '{print $5}' | cut -d: -f1 | sort -u | wc -l)
    
    aws cloudwatch put-metric-data \
        --namespace Minecraft/Security \
        --metric-data \
        "MetricName=ConcurrentConnections,Value=${concurrent_connections},Unit=Count" \
        "MetricName=UniqueIPs,Value=${unique_ips},Unit=Count"
}

# Main monitoring loop
while true; do
    monitor_ssh_attempts
    check_file_integrity
    monitor_connections
    sleep 300
done
SECURITY

    chmod +x ${mc_root}/monitor_security.sh

    # Create systemd service for security monitoring
    cat > /etc/systemd/system/minecraft-security-monitor.service << SERVICE
[Unit]
Description=Minecraft Server Security Monitor
After=minecraft.service
Requires=minecraft.service

[Service]
Type=simple
User=minecraft
ExecStart=${mc_root}/monitor_security.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
SERVICE

    # Setup audit logging
    cat > /etc/audit/rules.d/minecraft.rules << AUDIT
# Monitor minecraft directory access
-w ${mc_root} -p wa -k minecraft_files

# Monitor configuration changes
-w ${mc_root}/server.properties -p wa -k minecraft_config
-w ${mc_root}/whitelist.json -p wa -k minecraft_access
-w ${mc_root}/ops.json -p wa -k minecraft_access

# Monitor binary access
-w ${mc_root}/bedrock_server -p x -k minecraft_exec
-w ${mc_root}/server.jar -p r -k minecraft_exec

# Monitor service configuration
-w /etc/systemd/system/minecraft.service -p wa -k minecraft_service
AUDIT

    # Reload audit rules
    auditctl -R /etc/audit/rules.d/minecraft.rules

    systemctl enable minecraft-security-monitor
}

# Main execution flow
main() {
    log "Starting Minecraft server setup"
    
    setup_system
    optimize_system
    setup_minecraft_user
    setup_monitoring
    setup_backup_system
    
    if [ "${server_edition}" = "bedrock" ]; then
        setup_bedrock_server
    else
        setup_java_environment
        setup_java_server
    fi
    
    setup_server_service
    setup_service_recovery
    setup_performance_monitoring
    setup_health_check
    enhance_backup_validation
    tune_server_performance
    setup_resource_monitoring
    setup_recovery_procedures
    setup_status_reporting
    setup_security_hardening
    setup_security_monitoring
    
    # Start all services
    systemctl daemon-reload
    systemctl enable minecraft.service minecraft-backup.timer minecraft-monitor.service \
                  minecraft-health.timer minecraft-resources.service minecraft-status.service \
                  minecraft-security-monitor.service
    systemctl start minecraft.service minecraft-backup.timer minecraft-monitor.service \
                minecraft-health.timer minecraft-resources.service minecraft-status.service \
                minecraft-security-monitor.service
    
    log "Setup completed successfully"
}

# Execute main function
main

