# Backup validation Lambda
resource "aws_lambda_function" "backup_validator" {
  filename         = "${path.module}/lambda/backup_validator.zip"
  function_name    = "${var.name}-backup-validator"
  role            = aws_iam_role.backup_validator.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 60
  memory_size     = 128

  environment {
    variables = {
      BACKUP_BUCKET = local.bucket
      ALERT_TOPIC   = aws_sns_topic.minecraft_alerts[0].arn
    }
  }

  tags = local.cost_tags
}

# Add backup restore testing function
resource "aws_lambda_function" "backup_restore_test" {
  filename         = "${path.module}/lambda/backup_validator.zip"
  function_name    = "${var.name}-backup-restore-test"
  role            = aws_iam_role.backup_validator.arn
  handler         = "restore_test.handler"
  runtime         = "nodejs18.x"
  timeout         = 300
  memory_size     = 256

  environment {
    variables = {
      BACKUP_BUCKET = local.bucket
      ALERT_TOPIC   = aws_sns_topic.minecraft_alerts[0].arn
    }
  }

  tags = local.cost_tags
}

# IAM role for backup validator
resource "aws_iam_role" "backup_validator" {
  name = "${var.name}-backup-validator"

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
  name = "${var.name}-backup-validator-policy"
  role = aws_iam_role.backup_validator.id

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
            "cloudwatch:namespace": "MinecraftServer/Backups"
          }
        }
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

# Schedule backup validation
resource "aws_cloudwatch_event_rule" "backup_validation" {
  name                = "${var.name}-backup-validation"
  description         = "Trigger backup validation checks"
  schedule_expression = "rate(1 hour)"
  
  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "backup_validation" {
  rule      = aws_cloudwatch_event_rule.backup_validation.name
  target_id = "ValidateBackups"
  arn       = aws_lambda_function.backup_validator.arn
}

resource "aws_lambda_permission" "backup_validation" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_validator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_validation.arn
}

# Schedule weekly restore tests
resource "aws_cloudwatch_event_rule" "backup_restore_test" {
  name                = "${var.name}-backup-restore-test"
  description         = "Weekly backup restore testing"
  schedule_expression = "rate(7 days)"
  
  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "backup_restore_test" {
  rule      = aws_cloudwatch_event_rule.backup_restore_test.name
  target_id = "TestBackupRestore"
  arn       = aws_lambda_function.backup_restore_test.arn
}

# Backup monitoring alarms
resource "aws_cloudwatch_metric_alarm" "backup_age" {
  alarm_name          = "${var.name}-backup-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "BackupAge"
  namespace           = "MinecraftServer/Backups"
  period             = "3600"
  statistic          = "Maximum"
  threshold          = "86400000" # 24 hours in milliseconds
  alarm_description  = "Backup is more than 24 hours old"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "backup_size" {
  alarm_name          = "${var.name}-backup-size"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "BackupSize"
  namespace           = "MinecraftServer/Backups"
  period             = "3600"
  statistic          = "Minimum"
  threshold          = "1048576" # 1MB minimum size
  alarm_description  = "Backup size is suspiciously small"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  tags = local.cost_tags
}

# Add backup metrics to monitoring dashboard
resource "aws_cloudwatch_dashboard" "backup_monitoring" {
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
            ["MinecraftServer/Backups", "BackupSize"],
            [".", "BackupAge"]
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
            ["AWS/S3", "BucketSizeBytes", "BucketName", local.bucket, "StorageType", "StandardStorage"],
            ["...", "StandardIAStorage"],
            ["...", "GlacierStorage"]
          ]
          view    = "timeSeries"
          stacked = true
          region  = data.aws_region.current.name
          title   = "Storage by Class"
          period  = 86400
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer/Backups", "DifferentialRatio"],
            [".", "BackupLatency"],
            [".", "RestoreTestDuration"]
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
