# Maintenance Window Configuration
# --------------------------------------------

locals {
  maintenance_tags = merge(local.cost_tags, {
    Service = "MaintenanceWindow"
  })
  
  maintenance_script = <<-EOT
    #!/bin/bash
    set -e
    exec 1> >(logger -s -t $(basename $0)) 2>&1
    
    echo "Starting maintenance window tasks at $(date)"
    
    # Check disk space before maintenance
    DISK_SPACE=$(df -h ${var.mc_root} | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$DISK_SPACE" -gt 85 ]; then
      echo "WARNING: Disk space usage is high: $DISK_SPACE%"
      aws cloudwatch put-metric-data --namespace MinecraftServer \
        --metric-name MaintenanceDiskSpace --value $DISK_SPACE \
        --unit Percent --region ${data.aws_region.current.name}
    fi
    
    # Pre-maintenance backup with verification
    /usr/local/bin/graceful-shutdown.sh
    echo "Server stopped for maintenance, performing backup"
    
    # System updates with error tracking
    UPDATES_FAILED=0
    if command -v apt-get &> /dev/null; then
      apt-get update || UPDATES_FAILED=1
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || UPDATES_FAILED=1
    elif command -v dnf &> /dev/null; then
      dnf update -y || UPDATES_FAILED=1
    fi
    
    if [ $UPDATES_FAILED -eq 1 ]; then
      echo "ERROR: System updates failed"
      aws cloudwatch put-metric-data --namespace MinecraftServer \
        --metric-name MaintenanceUpdateFailure --value 1 \
        --unit Count --region ${data.aws_region.current.name}
    fi
    
    # Backup with verification
    cd ${var.mc_root}
    BACKUP_TIME=$(date +%Y%m%d-%H%M%S)
    BACKUP_FILE="world-$BACKUP_TIME.tar.gz"
    tar czf "$BACKUP_FILE" world/
    
    # Verify backup integrity
    if ! tar tzf "$BACKUP_FILE" > /dev/null; then
      echo "ERROR: Backup verification failed"
      aws cloudwatch put-metric-data --namespace MinecraftServer \
        --metric-name MaintenanceBackupFailure --value 1 \
        --unit Count --region ${data.aws_region.current.name}
      exit 1
    fi
    
    # Upload to S3 with checksum
    sha256sum "$BACKUP_FILE" > "${BACKUP_FILE}.sha256"
    aws s3 cp "$BACKUP_FILE" "s3://${local.bucket}/backups/maintenance/"
    aws s3 cp "${BACKUP_FILE}.sha256" "s3://${local.bucket}/backups/maintenance/"
    
    rm "$BACKUP_FILE" "${BACKUP_FILE}.sha256"
    
    # Cleanup with age and space monitoring
    DELETED_COUNT=$(find ${var.mc_root}/backups -type f -mtime +${var.backup_retention_days} -delete -print | wc -l)
    aws cloudwatch put-metric-data --namespace MinecraftServer \
      --metric-name MaintenanceFilesDeleted --value $DELETED_COUNT \
      --unit Count --region ${data.aws_region.current.name}
    
    # Server restart with health check
    systemctl start minecraft
    sleep 30
    
    if ! systemctl is-active --quiet minecraft; then
      echo "ERROR: Server failed to restart"
      aws cloudwatch put-metric-data --namespace MinecraftServer \
        --metric-name MaintenanceServerFailure --value 1 \
        --unit Count --region ${data.aws_region.current.name}
      exit 1
    fi
    
    # Record maintenance duration
    MAINTENANCE_DURATION=$SECONDS
    aws cloudwatch put-metric-data --namespace MinecraftServer \
      --metric-name MaintenanceDuration --value $MAINTENANCE_DURATION \
      --unit Seconds --region ${data.aws_region.current.name}
    
    echo "Maintenance completed successfully at $(date) (Duration: ${MAINTENANCE_DURATION}s)"
  EOT
}

#
# IAM Role for Maintenance Window
#

resource "aws_iam_role" "maintenance_window" {
  name        = "${var.name}-maintenance-window"
  description = "Role for Minecraft server maintenance window tasks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ssm.amazonaws.com"
      }
    }]
  })

  tags = local.maintenance_tags
}

resource "aws_iam_role_policy" "maintenance_window" {
  name = "${var.name}-maintenance-window"
  role = aws_iam_role.maintenance_window.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          module.s3.s3_bucket_arn,
          "${module.s3.s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.minecraft_alerts[0].arn
      }
    ]
  })
}

#
# Maintenance Window Definition
#

resource "aws_ssm_maintenance_window" "minecraft" {
  name                    = "${var.name}-maintenance-window"
  schedule               = var.maintenance_schedule
  duration              = var.maintenance_duration
  cutoff                = var.maintenance_cutoff
  schedule_timezone     = var.maintenance_timezone
  allow_unassociated_targets = false

  tags = local.maintenance_tags

  lifecycle {
    precondition {
      condition     = can(regex("^cron\\([^)]+\\)$|^rate\\([^)]+\\)$", var.maintenance_schedule))
      error_message = "maintenance_schedule must be a valid cron or rate expression"
    }
  }
}

resource "aws_ssm_maintenance_window_target" "minecraft" {
  window_id = aws_ssm_maintenance_window.minecraft.id
  name      = "${var.name}-server-maintenance"

  targets {
    key    = "InstanceIds"
    values = [module.ec2_minecraft.id[0]]
  }

  lifecycle {
    precondition {
      condition     = module.ec2_minecraft.id[0] != null
      error_message = "EC2 instance must exist before creating maintenance window target"
    }
  }
}

#
# Maintenance Tasks
#

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
      parameter {
        name   = "commands"
        values = [local.maintenance_script]
      }
      service_role_arn = aws_iam_role.maintenance_window.arn
      timeout_seconds  = var.maintenance_timeout
      output_s3_bucket = module.s3.s3_bucket_id
      output_s3_key_prefix = "maintenance-logs/"
      cloudwatch_config {
        cloudwatch_log_group_name = aws_cloudwatch_log_group.maintenance.name
        cloudwatch_output_enabled = true
      }
    }
  }
}

#
# Monitoring Resources
#

resource "aws_cloudwatch_log_group" "maintenance" {
  name              = "/aws/ssm/${var.name}/maintenance"
  retention_in_days = var.log_retention_days
  tags             = local.maintenance_tags
}

resource "aws_cloudwatch_metric_alarm" "maintenance_failure" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-maintenance-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "MaintenanceWindowExecutionStatusFailure"
  namespace           = "AWS/SSM"
  period             = "300"
  statistic          = "Sum"
  threshold          = "0"
  alarm_description  = "Maintenance window task execution failed for ${var.name} Minecraft server"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    MaintenanceWindowId = aws_ssm_maintenance_window.minecraft.id
  }

  tags = local.maintenance_tags
}

resource "aws_cloudwatch_metric_alarm" "maintenance_success" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-maintenance-success"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "MaintenanceWindowExecutionStatusSuccess"
  namespace           = "AWS/SSM"
  period             = "300"
  statistic          = "Sum"
  threshold          = "0"
  alarm_description  = "Maintenance window tasks completed successfully for ${var.name} Minecraft server"
  ok_actions         = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    MaintenanceWindowId = aws_ssm_maintenance_window.minecraft.id
  }

  tags = local.maintenance_tags
}

resource "aws_cloudwatch_metric_alarm" "maintenance_duration" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-maintenance-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "MaintenanceDuration"
  namespace           = "MinecraftServer"
  period             = "300"
  statistic          = "Maximum"
  threshold          = var.maintenance_timeout * 0.9
  alarm_description  = "Maintenance is taking longer than expected for ${var.name} Minecraft server"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    MaintenanceWindowId = aws_ssm_maintenance_window.minecraft.id
  }

  tags = local.maintenance_tags
}

resource "aws_cloudwatch_metric_alarm" "maintenance_backup_failure" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-maintenance-backup-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "MaintenanceBackupFailure"
  namespace           = "MinecraftServer"
  period             = "300"
  statistic          = "Sum"
  threshold          = "0"
  alarm_description  = "Backup operation failed during maintenance for ${var.name} Minecraft server"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    MaintenanceWindowId = aws_ssm_maintenance_window.minecraft.id
  }

  tags = local.maintenance_tags
}

resource "aws_cloudwatch_dashboard" "maintenance" {
  count          = var.enable_monitoring ? 1 : 0
  dashboard_name = "${var.name}-maintenance-status"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/SSM", "MaintenanceWindowExecutionStatusSuccess", "MaintenanceWindowId", aws_ssm_maintenance_window.minecraft.id],
            [".", "MaintenanceWindowExecutionStatusFailure", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Maintenance Window Execution Status"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer", "MaintenanceDuration"],
            [".", "MaintenanceBackupFailure"],
            [".", "MaintenanceUpdateFailure"],
            [".", "MaintenanceServerFailure"],
            [".", "MaintenanceFilesDeleted"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Maintenance Metrics"
          period  = 300
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          query   = "SOURCE '/aws/ssm/${var.name}/maintenance' | fields @timestamp, @message | sort @timestamp desc | limit 100"
          region  = data.aws_region.current.name
          title   = "Recent Maintenance Logs"
          view    = "table"
        }
      }
    ]
  })
}
