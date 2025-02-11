#!/bin/bash -ex

# System setup for Amazon Linux 2023 or Ubuntu
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case $ID in
        "amzn")
            dnf update -y
            dnf install -y unzip jq wget aws-cli amazon-cloudwatch-agent
            ;;
        "ubuntu")
            apt-get update
            apt-get -y upgrade
            apt-get -y install unzip jq wget awscli
            # Install CloudWatch agent
            wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
            dpkg -i -E ./amazon-cloudwatch-agent.deb
            rm amazon-cloudwatch-agent.deb
            ;;
    esac
fi

# Performance optimizations for game server
echo "net.core.rmem_max = 16777216" >> /etc/sysctl.conf
echo "net.core.wmem_max = 16777216" >> /etc/sysctl.conf
echo "net.ipv4.tcp_rmem = 4096 87380 16777216" >> /etc/sysctl.conf
echo "net.ipv4.tcp_wmem = 4096 87380 16777216" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
sysctl -p

# Create minecraft user and directories
useradd -r -m -U -d ${mc_root} -s /bin/bash minecraft

# Setup graceful shutdown
cat > /usr/local/bin/minecraft-shutdown << 'SHUTDOWN'
#!/bin/bash
. /etc/minecraft/server.env
/usr/local/bin/graceful-shutdown.sh
SHUTDOWN

chmod +x /usr/local/bin/minecraft-shutdown

mkdir -p /etc/minecraft
cat > /etc/minecraft/server.env << ENV
mc_root=${mc_root}
mc_bucket=${mc_bucket}
server_edition=${server_edition}
ENV

# Install shutdown service and script
cp ${mc_root}/minecraft-shutdown.service /etc/systemd/system/
cp ${mc_root}/graceful_shutdown.sh /usr/local/bin/graceful-shutdown.sh
chmod +x /usr/local/bin/graceful-shutdown.sh
systemctl enable minecraft-shutdown.service

# Configure CloudWatch agent for game metrics
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOL'
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root"
    },
    "metrics": {
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
                    "mem_available_percent"
                ],
                "metrics_collection_interval": 60
            },
            "net": {
                "measurement": [
                    "bytes_sent",
                    "bytes_recv",
                    "packets_sent",
                    "packets_recv"
                ],
                "metrics_collection_interval": 60
            },
            "disk": {
                "measurement": [
                    "used_percent",
                    "inodes_free"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            }
        },
        "force_flush_interval": 30
    }
}
EOL

systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# Make sure we have a minecraft folder owned by minecraft user
if [ ! -d ${mc_root} ]; then
    mkdir -p ${mc_root}
fi

chown minecraft:minecraft ${mc_root}

# AWS command for S3 sync
AWS="aws --region $(curl -s http://169.254.169.254/latest/meta-data/placement/region)"

# Download Bedrock server
function download_bedrock_server() {
    DOWNLOAD_URL=$(curl -s https://www.minecraft.net/en-us/download/server/bedrock | grep -o 'https://minecraft.azureedge.net/bin-linux/[^"]*')
    
    if [ -z "$DOWNLOAD_URL" ]; then
        echo "Failed to get Bedrock server download URL"
        exit 1
    }

    wget -O ${mc_root}/bedrock-server.zip "$DOWNLOAD_URL"
    unzip -o ${mc_root}/bedrock-server.zip -d ${mc_root}
    rm ${mc_root}/bedrock-server.zip
    chmod +x ${mc_root}/bedrock_server
}

# Download Java server
function download_java_server() {
    VERSION_MANIFEST="https://launchermeta.mojang.com/mc/game/version_manifest.json"
    if [ "${mc_version}" = "latest" ]; then
        MC_VERS=$(curl -s $VERSION_MANIFEST | jq -r '.versions[0].id')
    else
        MC_VERS="${mc_version}"
    fi
    
    VERSIONS_URL=$(curl -s $VERSION_MANIFEST | jq -r --arg VER "$MC_VERS" '.versions[] | select(.id==$VER) | .url')
    SERVER_URL=$(curl -s $VERSIONS_URL | jq -r '.downloads.server.url')
    
    wget -O ${mc_root}/server.jar "$SERVER_URL"
}

# Switch to minecraft user
cd ${mc_root}
su minecraft << 'EOF'
# Sync from S3 if bucket exists
aws s3 sync s3://${mc_bucket} ${mc_root}

# Server-specific setup for Bedrock
if [ ! -f ${mc_root}/bedrock_server ]; then
    download_bedrock_server
fi

# Optimize server properties for small player count
cat > server.properties << PROP
server-name=AWS Minecraft Server
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
PROP

# Create startup script with memory optimizations
cat > start_server.sh << 'BEDROCK'
#!/bin/bash
LD_LIBRARY_PATH=. ./bedrock_server
BEDROCK
chmod +x start_server.sh

# Setup backup script
cat > backup.sh << 'BACKUP'
#!/bin/bash
aws s3 sync ${mc_root} s3://${mc_bucket} --delete
BACKUP
chmod +x backup.sh
EOF

# Create systemd service
cat > /etc/systemd/system/minecraft.service << SERVICE
[Unit]
Description=Minecraft Bedrock Server
After=network.target

[Service]
Type=simple
User=minecraft
WorkingDirectory=${mc_root}
ExecStart=${mc_root}/start_server.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
SERVICE

# Create backup timer
cat > /etc/systemd/system/minecraft-backup.timer << TIMER
[Unit]
Description=Minecraft Server Backup Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=${mc_backup_freq}m

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/minecraft-backup.service << BACKUPSVC
[Unit]
Description=Minecraft Server Backup Service
After=minecraft.service

[Service]
Type=oneshot
User=minecraft
ExecStart=${mc_root}/backup.sh
BACKUPSVC

# Enable and start services
systemctl enable minecraft.service minecraft-backup.timer
systemctl start minecraft.service minecraft-backup.timer

