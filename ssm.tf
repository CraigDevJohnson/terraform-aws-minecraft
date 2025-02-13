# Systems Manager (SSM) Configuration
# -------------------------------------

# Local variables for SSM resources
locals {
  ssm_tags = merge(module.label.tags, {
    Service = "SSM"
  })

  # Maintenance window configuration
  maintenance_window = {
    duration = "2"  # 2-hour maintenance window
    cutoff   = "1"  # Stop scheduling new tasks 1 hour before end
  }

  # Session Manager configuration
  session_manager = {
    log_retention = 30  # days to retain session logs
  }
}

# Maintenance Windows
# ------------------

resource "aws_ssm_maintenance_window" "minecraft" {
  name                       = "${var.name}-maintenance"
  schedule                   = var.maintenance_schedule
  duration                   = local.maintenance_window.duration
  cutoff                     = local.maintenance_window.cutoff
  allow_unassociated_targets = false
  tags                       = local.ssm_tags
}

resource "aws_ssm_maintenance_window_target" "minecraft" {
  window_id     = aws_ssm_maintenance_window.minecraft.id
  name          = "${var.name}-server"
  description   = "Target for Minecraft server maintenance"
  resource_type = "INSTANCE"

  targets {
    key    = "InstanceIds"
    values = [module.ec2_minecraft.id[0]]
  }
}

resource "aws_ssm_maintenance_window_task" "minecraft_maintenance" {
  name            = "${var.name}-server-maintenance"
  max_concurrency = "1"
  max_errors      = "1"
  priority        = 1
  task_arn        = "AWS-RunShellScript"
  task_type       = "RUN_COMMAND"
  window_id       = aws_ssm_maintenance_window.minecraft.id

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.minecraft.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      timeout_seconds = 3600
      parameter {
        name   = "commands"
        values = [
          "systemctl stop minecraft",
          "aws s3 sync ${var.mc_root} s3://${local.bucket}/backups/$(date +%Y%m%d)/",
          "find ${var.mc_root}/logs -type f -mtime +7 -delete",
          "systemctl start minecraft"
        ]
      }
    }
  }
}

# SSM Documents
# ------------

resource "aws_ssm_document" "server_maintenance" {
  name            = "${var.name}-maintenance"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Maintenance tasks for Minecraft server"
    parameters = {
      BackupBucket = {
        type        = "String"
        description = "S3 bucket for backups"
        default     = local.bucket
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "performMaintenance"
      inputs = {
        runCommand = [
          "systemctl stop minecraft",
          "aws s3 sync ${var.mc_root} s3://${local.bucket}/backups/$(date +%Y%m%d)/",
          "find ${var.mc_root}/logs -type f -mtime +7 -delete",
          "systemctl start minecraft"
        ]
      }
    }]
  })

  tags = local.ssm_tags
}

resource "aws_ssm_document" "minecraft_performance_test" {
  name            = "${var.name}-performance-test"
  document_type   = "Command"
  document_format = "YAML"
  
  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Performance testing suite for Minecraft server"
    parameters = {
      TestType = {
        type          = "String"
        description   = "Type of test to run (player/combat/redstone)"
        allowedValues = ["player", "combat", "redstone"]
      }
      Duration = {
        type        = "String"
        description = "Test duration in minutes"
        default     = "5"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "runPerformanceTest"
      inputs = {
        runCommand = [
          "#!/bin/bash",
          "case $TestType in",
          "  player)",
          "    ${var.mc_root}/tools/simulate_players.sh $Duration",
          "    ;;",
          "  combat)",
          "    ${var.mc_root}/tools/simulate_combat.sh $Duration",
          "    ;;",
          "  redstone)",
          "    ${var.mc_root}/tools/activate_redstone.sh $Duration",
          "    ;;",
          "esac"
        ]
      }
    }]
  })

  tags = local.ssm_tags
}

# SSM Parameters
# -------------

resource "aws_ssm_parameter" "server_config" {
  name        = "/minecraft/${var.name}/config"
  description = "Minecraft server configuration parameters"
  type        = "String"
  value = jsonencode({
    serverEdition = var.server_edition
    mcVersion     = var.mc_version
    backupFreq    = var.mc_backup_freq
    activeHours = {
      start = var.active_hours_start
      end   = var.active_hours_end
    }
  })

  tags = local.ssm_tags
}

# Session Manager Configuration
# ---------------------------

resource "aws_ssm_document" "session_preferences" {
  name            = "${var.name}-session-preferences"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager preferences for Minecraft server"
    sessionType   = "Standard_Stream"
    inputs = {
      cloudWatchLogGroupName     = aws_cloudwatch_log_group.session_manager.name
      cloudWatchEncryptionEnabled = true
      cloudWatchStreamingEnabled = true
      idleSessionTimeout        = "30"
      maxSessionDuration       = "240"
      shellProfile = {
        linux   = "export TMOUT=1800\nexport HISTTIMEFORMAT='%F %T '\nexport PROMPT_COMMAND='history -a'"
        windows = "Set-PSReadLineOption -HistorySaveStyle SaveIncrementally"
      }
    }
  })

  tags = local.ssm_tags
}

resource "aws_cloudwatch_log_group" "session_manager" {
  name              = "/aws/ssm/minecraft/${var.name}"
  retention_in_days = local.session_manager.log_retention
  tags              = local.ssm_tags
}

# IAM Configurations
# ----------------

resource "aws_iam_role_policy" "session_manager_logging" {
  name = "${var.name}-session-manager-logging"
  role = aws_iam_role.minecraft_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "${aws_cloudwatch_log_group.session_manager.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "session_manager" {
  role       = aws_iam_role.minecraft_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
