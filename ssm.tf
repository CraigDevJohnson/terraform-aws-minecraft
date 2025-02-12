# Maintenance window configuration
resource "aws_ssm_maintenance_window" "minecraft" {
  name                       = "${var.name}-maintenance"
  schedule                   = var.maintenance_schedule
  duration                   = "2"
  cutoff                     = "1"
  allow_unassociated_targets = false

  tags = local.cost_tags
}

resource "aws_ssm_maintenance_window_target" "minecraft" {
  window_id     = aws_ssm_maintenance_window.minecraft.id
  name          = "minecraft-server"
  resource_type = "INSTANCE"

  targets {
    key    = "InstanceIds"
    values = [module.ec2_minecraft.id[0]]
  }
}

# Maintenance tasks
resource "aws_ssm_maintenance_window_task" "minecraft_maintenance" {
  name            = "minecraft-server-maintenance"
  max_concurrency = "1"
  max_errors      = "1"
  priority        = 1
  task_arn        = "AWS-RunShellScript"
  task_type       = "RUN_COMMAND"
  window_id       = aws_ssm_maintenance_window.minecraft.id

  // ...existing code for task configuration...
}

resource "aws_ssm_maintenance_window_task" "minecraft_maintenance_cleanup" {
  name            = "minecraft-maintenance-cleanup"
  max_concurrency = "1"
  max_errors      = "1"
  priority        = 2
  task_arn        = "AWS-RunShellScript"
  task_type       = "RUN_COMMAND"
  window_id       = aws_ssm_maintenance_window.minecraft.id

  // ...existing code for cleanup task configuration...
}

# SSM parameters for server configuration
resource "aws_ssm_parameter" "server_config" {
  name = "/minecraft/${module.ec2_minecraft.id[0]}/config"
  type = "String"
  value = jsonencode({
    serverEdition = var.server_edition
    mcVersion     = var.mc_version
    backupFreq    = var.mc_backup_freq
    activeHours = {
      start = var.active_hours_start
      end   = var.active_hours_end
    }
  })

  tags = local.cost_tags
}

# SSM document for server maintenance
resource "aws_ssm_document" "server_maintenance" {
  name            = "${var.name}-maintenance"
  document_type   = "Command"
  document_format = "YAML"

  content = <<DOC
schemaVersion: '2.2'
description: 'Maintenance tasks for Minecraft server'
parameters:
  BackupBucket:
    type: String
    description: S3 bucket for backups
    default: ${local.bucket}
mainSteps:
  - action: aws:runShellScript
    name: performMaintenance
    inputs:
      runCommand:
        - systemctl stop minecraft
        - aws s3 sync ${var.mc_root} s3://${local.bucket}/backups/$(date +%Y%m%d)/
        - find ${var.mc_root}/logs -type f -mtime +7 -delete
        - systemctl start minecraft
DOC

  tags = local.cost_tags
}

# SSM Document for simulating player connections
resource "aws_ssm_document" "minecraft_simulate_player" {
  name            = "Minecraft-SimulatePlayer"
  document_type   = "Command"
  document_format = "YAML"
  
  content = <<-DOC
    schemaVersion: '2.2'
    description: 'Simulate a player connection for performance testing'
    parameters:
      PlayerNumber:
        type: String
        description: The player number to simulate
    mainSteps:
      - action: 'aws:runShellScript'
        name: 'simulatePlayer'
        inputs:
          runCommand:
            - |
              #!/bin/bash
              PLAYER_NUM="{{ PlayerNumber }}"
              echo "Simulating player ${PLAYER_NUM}"
              
              # Create test player data
              mkdir -p /tmp/test_players
              cat > "/tmp/test_players/player${PLAYER_NUM}.json" << EOF
              {
                "name": "TestPlayer${PLAYER_NUM}",
                "position": {
                  "x": $((RANDOM % 1000 - 500)),
                  "y": 64,
                  "z": $((RANDOM % 1000 - 500))
                }
              }
              EOF
              
              # Simulate player actions
              while true; do
                # Move randomly
                x=$((RANDOM % 10 - 5))
                z=$((RANDOM % 10 - 5))
                echo "Player ${PLAYER_NUM} moving to offset (${x}, ${z})"
                sleep 1
              done &
              PID=$!
              
              # Store PID for cleanup
              echo $PID > "/tmp/test_players/player${PLAYER_NUM}.pid"
  DOC

  tags = local.common_tags
}

# SSM Document for teleporting players (chunk generation test)
resource "aws_ssm_document" "minecraft_teleport_players" {
  name            = "Minecraft-TeleportPlayers"
  document_type   = "Command"
  document_format = "YAML"
  
  content = <<-DOC
    schemaVersion: '2.2'
    description: 'Teleport players to generate new chunks'
    parameters:
      Distance:
        type: String
        description: Distance to teleport players
    mainSteps:
      - action: 'aws:runShellScript'
        name: 'teleportPlayers'
        inputs:
          runCommand:
            - |
              #!/bin/bash
              DISTANCE="{{ Distance }}"
              
              # Get list of test players
              for player in /tmp/test_players/player*.json; do
                if [ -f "$player" ]; then
                  PLAYER_NUM=$(basename "$player" .json | sed 's/player//')
                  
                  # Calculate new position
                  angle=$((PLAYER_NUM * 360 / $(ls /tmp/test_players/player*.json | wc -l)))
                  x=$(echo "scale=0; ${DISTANCE} * c($angle * 3.14159 / 180)" | bc -l)
                  z=$(echo "scale=0; ${DISTANCE} * s($angle * 3.14159 / 180)" | bc -l)
                  
                  echo "Teleporting player ${PLAYER_NUM} to ($x, $z)"
                done
              done
  DOC

  tags = local.common_tags
}

# SSM Document for simulating combat
resource "aws_ssm_document" "minecraft_simulate_combat" {
  name            = "Minecraft-SimulateCombat"
  document_type   = "Command"
  document_format = "YAML"
  
  content = <<-DOC
    schemaVersion: '2.2'
    description: 'Simulate combat scenarios for performance testing'
    mainSteps:
      - action: 'aws:runShellScript'
        name: 'simulateCombat'
        inputs:
          runCommand:
            - |
              #!/bin/bash
              
              # Group players for combat simulation
              player_count=$(ls /tmp/test_players/player*.json | wc -l)
              for ((i=1; i<=player_count/2; i++)); do
                player1=$((i*2-1))
                player2=$((i*2))
                
                echo "Setting up combat between Player${player1} and Player${player2}"
                
                # Move players close to each other
                x=$((RANDOM % 100 - 50))
                z=$((RANDOM % 100 - 50))
                
                # Update player positions
                sed -i "s/\"x\": [0-9-]*/\"x\": $x/" "/tmp/test_players/player${player1}.json"
                sed -i "s/\"x\": [0-9-]*/\"x\": $((x+2))/" "/tmp/test_players/player${player2}.json"
                sed -i "s/\"z\": [0-9-]*/\"z\": $z/" "/tmp/test_players/player${player1}.json"
                sed -i "s/\"z\": [0-9-]*/\"z\": $z/" "/tmp/test_players/player${player2}.json"
                
                # Simulate combat actions
                (
                  while true; do
                    echo "Combat action: Player${player1} vs Player${player2}"
                    sleep 0.5
                  done
                ) &
              done
  DOC

  tags = local.common_tags
}

# SSM Document for activating redstone
resource "aws_ssm_document" "minecraft_activate_redstone" {
  name            = "Minecraft-ActivateRedstone"
  document_type   = "Command"
  document_format = "YAML"
  
  content = <<-DOC
    schemaVersion: '2.2'
    description: 'Activate redstone contraptions for performance testing'
    mainSteps:
      - action: 'aws:runShellScript'
        name: 'activateRedstone'
        inputs:
          runCommand:
            - |
              #!/bin/bash
              
              # Define test contraptions
              declare -a contraptions=(
                "clock"
                "piston_array"
                "item_sorter"
                "door_array"
              )
              
              # Activate each contraption
              for contraption in "${contraptions[@]}"; do
                echo "Activating redstone contraption: ${contraption}"
                
                case $contraption in
                  "clock")
                    # Simulate rapid redstone clock
                    (
                      while true; do
                        echo "Clock tick"
                        sleep 0.1
                      done
                    ) &
                    ;;
                  "piston_array")
                    # Simulate piston array movement
                    (
                      while true; do
                        echo "Piston activation"
                        sleep 0.2
                      done
                    ) &
                    ;;
                  *)
                    echo "Activating generic contraption: ${contraption}"
                    ;;
                esac
              done
  DOC

  tags = local.common_tags
}

# SSM Document for stopping tests
resource "aws_ssm_document" "minecraft_stop_tests" {
  name            = "Minecraft-StopTests"
  document_type   = "Command"
  document_format = "YAML"
  
  content = <<-DOC
    schemaVersion: '2.2'
    description: 'Stop all running performance tests'
    mainSteps:
      - action: 'aws:runShellScript'
        name: 'stopTests'
        inputs:
          runCommand:
            - |
              #!/bin/bash
              
              # Stop all test player processes
              if [ -d "/tmp/test_players" ]; then
                for pid_file in /tmp/test_players/*.pid; do
                  if [ -f "$pid_file" ]; then
                    pid=$(cat "$pid_file")
                    kill -9 $pid 2>/dev/null || true
                  fi
                done
                
                # Clean up test files
                rm -rf /tmp/test_players
              fi
              
              # Stop any remaining test processes
              pkill -f "simulatePlayer" || true
              pkill -f "simulateCombat" || true
              pkill -f "activateRedstone" || true
  DOC

  tags = local.common_tags
}

# SSM role attachments
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "session_manager_logging" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# Session Manager logging
resource "aws_cloudwatch_log_group" "session_manager" {
  name              = "/aws/ssm/minecraft/${var.name}"
  retention_in_days = 30

  tags = local.cost_tags
}
