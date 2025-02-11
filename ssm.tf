# Maintenance window configuration
resource "aws_ssm_maintenance_window" "minecraft" {
  name                = "${var.name}-maintenance"
  schedule            = var.maintenance_schedule
  duration            = "2"
  cutoff              = "1"
  allow_unassociated_targets = false
  
  tags = local.cost_tags
}

resource "aws_ssm_maintenance_window_target" "minecraft" {
  window_id      = aws_ssm_maintenance_window.minecraft.id
  name           = "minecraft-server"
  resource_type  = "INSTANCE"
  
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
  name  = "/minecraft/${module.ec2_minecraft.id[0]}/config"
  type  = "String"
  value = jsonencode({
    serverEdition = var.server_edition
    mcVersion     = var.mc_version
    backupFreq    = var.mc_backup_freq
    activeHours   = {
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
