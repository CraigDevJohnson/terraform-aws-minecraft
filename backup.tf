# Backup infrastructure configuration
# Manages backup validation, testing, and monitoring resources

# Variables validation for backup configuration
locals {
  backup_validation_error = var.enable_monitoring && (
    var.backup_retention_days == null ||
    var.backup_retention_days < 1 ||
    var.backup_retention_days > 365
  ) ? "backup_retention_days must be between 1 and 365 when monitoring is enabled" : null

  # Backup retention policies
  backup_retention_config = {
    differential = 7   # Keep differential backups for 7 days
    full        = 30   # Keep full backups for 30 days
    archive     = 90   # Move to Glacier after 90 days
  }
}

resource "null_resource" "backup_validation" {
  count = local.backup_validation_error != null ? "Please fix: ${local.backup_validation_error}" : 0
}

# AWS Backup vault for additional protection
resource "aws_backup_vault" "minecraft" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-vault"
  tags  = merge(local.cost_tags, {
    BackupType = "GameServer"
    Component  = "Backup"
  })
}

resource "aws_backup_plan" "minecraft" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-backup-plan"

  rule {
    rule_name         = "weekly-full-backup"
    target_vault_name = aws_backup_vault.minecraft[0].name
    schedule          = "cron(0 0 ? * 1 *)" # Every Sunday at midnight

    lifecycle {
      delete_after = var.backup_retention_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.minecraft[0].arn
      lifecycle {
        cold_storage_after = 30
        delete_after      = 90
      }
    }
  }

  advanced_backup_setting {
    backup_options = {
      WindowsVSS = "enabled"
    }
    resource_type = "EC2"
  }

  tags = merge(local.cost_tags, {
    BackupType = "GameServer"
    Component  = "Backup"
  })
}

# IAM role for AWS Backup service
resource "aws_iam_role" "aws_backup" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-aws-backup-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "backup.amazonaws.com"
      }
    }]
  })
}

# IAM policy for AWS Backup
resource "aws_iam_role_policy_attachment" "aws_backup" {
  count      = var.enable_monitoring ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
  role       = aws_iam_role.aws_backup[0].name
}

# AWS Backup selection
resource "aws_backup_selection" "minecraft" {
  count        = var.enable_monitoring ? 1 : 0
  name         = "${var.name}-backup-selection"
  iam_role_arn = aws_iam_role.aws_backup[0].arn
  plan_id      = aws_backup_plan.minecraft[0].id

  resources = [
    module.ec2_minecraft.id[0]
  ]
}

# S3 lifecycle rules for backup management
resource "aws_s3_bucket_lifecycle_configuration" "backup_lifecycle" {
  bucket = local.bucket

  rule {
    id     = "differential-backups"
    status = "Enabled"

    filter {
      prefix = "backups/differential/"
      tags = {
        BackupType = "Differential"
        Component  = "MinecraftServer"
      }
    }

    expiration {
      days = local.backup_retention_config.differential
    }

    transition {
      days          = 1
      storage_class = "STANDARD_IA"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "full-backups"
    status = "Enabled"

    filter {
      prefix = "backups/full/"
      tags = {
        BackupType = "Full"
        Component  = "MinecraftServer"
      }
    }

    transition {
      days          = local.backup_retention_config.full
      storage_class = "GLACIER"
    }

    expiration {
      days = local.backup_retention_config.archive
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Primary backup validator Lambda function
resource "aws_lambda_function" "backup_validator" {
  count         = var.enable_monitoring ? 1 : 0
  filename      = "${path.module}/lambda/backup_validator.zip"
  function_name = "${var.name}-backup-validator"
  role          = aws_iam_role.backup_validator[0].arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 60
  memory_size   = 128
  description   = "Validates Minecraft server backups and monitors backup health"

  environment {
    variables = {
      BACKUP_BUCKET = local.bucket
      ALERT_TOPIC   = aws_sns_topic.minecraft_alerts[0].arn
    }
  }

  tags = local.cost_tags
}

# Dedicated backup restore testing Lambda
resource "aws_lambda_function" "backup_restore_test" {
  count         = var.enable_monitoring ? 1 : 0
  filename      = "${path.module}/lambda/backup_restore_test.zip"
  function_name = "${var.name}-backup-restore-test"
  role          = aws_iam_role.backup_restore_test[0].arn # Separate role for restore testing
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 300
  memory_size   = 256
  description   = "Performs automated restore testing of Minecraft server backups"

  environment {
    variables = {
      BACKUP_BUCKET = local.bucket
      ALERT_TOPIC   = aws_sns_topic.minecraft_alerts[0].arn
      RESTORE_PATH  = "/tmp/minecraft-restore-test"
    }
  }

  tags = local.cost_tags
}

# IAM role for backup validator
resource "aws_iam_role" "backup_validator" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-backup-validator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = local.cost_tags
}

# IAM role for backup restore testing
resource "aws_iam_role" "backup_restore_test" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-backup-restore-test"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = local.cost_tags
}

# IAM policy for backup validator
resource "aws_iam_role_policy" "backup_validator" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-backup-validator-policy"
  role  = aws_iam_role.backup_validator[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:HeadObject"
        ]
        Resource = [
          module.s3.s3_bucket_arn,
          "${module.s3.s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" : "MinecraftServer/Backups"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.minecraft_alerts[0].arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# IAM policy for backup restore testing
resource "aws_iam_role_policy" "backup_restore_test" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-backup-restore-test-policy"
  role  = aws_iam_role.backup_restore_test[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:HeadObject"
        ]
        Resource = [
          module.s3.s3_bucket_arn,
          "${module.s3.s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" : "MinecraftServer/Backups"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.minecraft_alerts[0].arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Schedule for backup validation
resource "aws_cloudwatch_event_rule" "backup_validation" {
  count               = var.enable_monitoring ? 1 : 0
  name                = "${var.name}-backup-validation"
  description         = "Trigger backup validation checks"
  schedule_expression = "rate(1 hour)"

  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "backup_validation" {
  count     = var.enable_monitoring ? 1 : 0
  rule      = aws_cloudwatch_event_rule.backup_validation[0].name
  target_id = "ValidateBackups"
  arn       = aws_lambda_function.backup_validator[0].arn
}

resource "aws_lambda_permission" "backup_validation" {
  count         = var.enable_monitoring ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_validator[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_validation[0].arn
}

# Schedule for weekly restore tests
resource "aws_cloudwatch_event_rule" "backup_restore_test" {
  count               = var.enable_monitoring ? 1 : 0
  name                = "${var.name}-backup-restore-test"
  description         = "Weekly backup restore testing"
  schedule_expression = "rate(7 days)"

  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "backup_restore_test" {
  count     = var.enable_monitoring ? 1 : 0
  rule      = aws_cloudwatch_event_rule.backup_restore_test[0].name
  target_id = "TestBackupRestore"
  arn       = aws_lambda_function.backup_restore_test[0].arn
}

resource "aws_lambda_permission" "backup_restore_test" {
  count         = var.enable_monitoring ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_restore_test[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_restore_test[0].arn
}

# CloudWatch alarms for backup monitoring
resource "aws_cloudwatch_metric_alarm" "backup_age" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-backup-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "BackupAge"
  namespace           = "MinecraftServer/Backups"
  period              = "3600"
  statistic           = "Maximum"
  threshold           = "86400000" # 24 hours in milliseconds
  alarm_description   = "Backup is more than 24 hours old"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]
  dimensions = {
    ServerInstance = module.ec2_minecraft.id[0]
  }

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "backup_size" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-backup-size"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "BackupSize"
  namespace           = "MinecraftServer/Backups"
  period              = "3600"
  statistic           = "Minimum"
  threshold           = "1048576" # 1MB minimum size
  alarm_description   = "Backup size is suspiciously small"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]
  dimensions = {
    ServerInstance = module.ec2_minecraft.id[0]
  }

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "backup_restore_failure" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-backup-restore-test-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "RestoreTestFailure"
  namespace           = "MinecraftServer/Backups"
  period              = "3600"
  statistic           = "Maximum"
  threshold           = "0"
  alarm_description   = "Backup restore test has failed"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]
  dimensions = {
    ServerInstance = module.ec2_minecraft.id[0]
  }

  tags = local.cost_tags
}

# CloudWatch dashboard for backup monitoring
resource "aws_cloudwatch_dashboard" "backup_monitoring" {
  count          = var.enable_monitoring ? 1 : 0
  dashboard_name = "${var.name}-backup-monitoring"

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
            ["MinecraftServer/Backups", "BackupSize", "ServerInstance", module.ec2_minecraft.id[0]],
            [".", "BackupAge", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Backup Metrics"
          period  = 3600
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
            ["MinecraftServer/Backups", "StorageCostEstimate", "ServerInstance", module.ec2_minecraft.id[0]],
            ["AWS/S3", "BucketSizeBytes", "BucketName", local.bucket, "StorageType", "StandardStorage"],
            ["...", "StandardIAStorage"],
            ["...", "GlacierStorage"]
          ]
          view    = "timeSeries"
          stacked = true
          region  = data.aws_region.current.name
          title   = "Storage Usage and Cost"
          period  = 86400
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer/Backups", "DifferentialRatio", "ServerInstance", module.ec2_minecraft.id[0]],
            [".", "BackupDuration", ".", "."],
            [".", "RestoreTestDuration", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Backup Performance Metrics"
          period  = 3600
        }
      }
    ]
  })
}
