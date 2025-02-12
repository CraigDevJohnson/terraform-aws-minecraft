# Maintenance window configuration
resource "aws_ssm_maintenance_window" "minecraft" {
  name              = "${var.name}-maintenance-window"
  schedule          = "cron(0 0 ? * MON *)" // Every Monday at midnight
  duration          = "2"
  cutoff            = "1"
  schedule_timezone = "UTC"

  tags = local.cost_tags
}

resource "aws_ssm_maintenance_window_target" "minecraft" {
  window_id = aws_ssm_maintenance_window.minecraft.id
  name      = "minecraft-server-maintenance"

  targets {
    key    = "InstanceIds"
    values = [module.ec2_minecraft.id[0]]
  }
}

resource "aws_ssm_maintenance_window_task" "minecraft_maintenance" {
  name            = "minecraft-server-maintenance"
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
        name = "commands"
        values = [
          "#!/bin/bash",
          "echo 'Starting maintenance window tasks'",
          # System updates
          "if command -v apt-get &> /dev/null; then",
          "    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y",
          "elif command -v dnf &> /dev/null; then",
          "    dnf update -y",
          "fi",
          # Backup current state
          "/usr/local/bin/graceful-shutdown.sh",
          "sleep 30",
          # Cleanup old files
          "find ${var.mc_root}/backups -type f -mtime +30 -delete",
          # Optimize world files
          "cd ${var.mc_root}",
          "tar czf world-$(date +%Y%m%d).tar.gz world/",
          "aws s3 cp world-$(date +%Y%m%d).tar.gz s3://${local.bucket}/backups/",
          "rm world-$(date +%Y%m%d).tar.gz",
          # Restart server
          "systemctl start minecraft"
        ]
      }
      service_role_arn = aws_iam_role.maintenance_window.arn
      timeout_seconds  = 3600
    }
  }
}

# Cleanup tasks for maintenance window
resource "aws_ssm_maintenance_window_task" "minecraft_maintenance_cleanup" {
  name            = "minecraft-maintenance-cleanup"
  max_concurrency = "1"
  max_errors      = "1"
  priority        = 2
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
        name = "commands"
        values = [
          "#!/bin/bash",
          "if ! systemctl is-active --quiet minecraft; then",
          "    echo 'Server appears to be stopped after maintenance, attempting recovery'",
          "    systemctl start minecraft",
          "    sleep 30",
          "    if ! systemctl is-active --quiet minecraft; then",
          "        aws sns publish --topic-arn ${aws_sns_topic.minecraft_alerts[0].arn} --message 'Server failed to restart after maintenance'",
          "    fi",
          "fi",
          "find /tmp -name 'minecraft_maintenance_*' -type f -mtime +1 -delete"
        ]
      }
      service_role_arn = aws_iam_role.maintenance_window.arn
      timeout_seconds  = 600
    }
  }
}

# Maintenance window monitoring
resource "aws_cloudwatch_metric_alarm" "maintenance_failure" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-maintenance-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "MaintenanceWindowExecutionStatusFailure"
  namespace           = "AWS/SSM"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Maintenance window task execution failed"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    MaintenanceWindowId = aws_ssm_maintenance_window.minecraft.id
  }

  tags = local.cost_tags
}
