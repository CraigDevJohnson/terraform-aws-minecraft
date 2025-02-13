# Variables validation
locals {
  analytics_validation_error = var.enable_monitoring && (
    var.metric_retention_days == null ||
    var.metric_retention_days < 1 ||
    var.metric_retention_days > 365
  ) ? "metric_retention_days must be between 1 and 365 when monitoring is enabled" : null
}

resource "null_resource" "analytics_validation" {
  count = local.analytics_validation_error != null ? "Please fix: ${local.analytics_validation_error}" : 0
}

# DynamoDB table for player statistics
resource "aws_dynamodb_table" "player_stats" {
  count        = var.enable_monitoring ? 1 : 0
  name         = "${var.name}-player-stats"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "playerId"
  range_key    = "timestamp"

  attribute {
    name = "playerId"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.cost_tags, {
    Purpose = "Player Analytics"
  })
}

# SNS Topic for retention alerts
resource "aws_sns_topic" "retention_alerts" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-retention-alerts"
  tags  = local.cost_tags
}

# Lambda function for player analytics
resource "aws_lambda_function" "player_analytics" {
  count         = var.enable_monitoring ? 1 : 0
  filename      = "${path.module}/lambda/player_analytics.zip"
  function_name = "${var.name}-player-analytics"
  role          = aws_iam_role.player_analytics[0].arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 60
  memory_size   = 256
  description   = "Analyzes player activity and retention metrics for the Minecraft server"

  environment {
    variables = {
      STATS_TABLE      = aws_dynamodb_table.player_stats[0].name
      ALERT_TOPIC_ARN  = aws_sns_topic.retention_alerts[0].arn
    }
  }

  tags = local.cost_tags
}

# IAM role for player analytics Lambda
resource "aws_iam_role" "player_analytics" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-player-analytics-role"

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
}

# IAM policy for player analytics
resource "aws_iam_role_policy" "player_analytics" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-player-analytics-policy"
  role  = aws_iam_role.player_analytics[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.player_stats[0].arn
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.retention_alerts[0].arn
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

# Player analytics dashboard
resource "aws_cloudwatch_dashboard" "player_analytics" {
  count          = var.enable_monitoring ? 1 : 0
  dashboard_name = "${var.name}-player-analytics"

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
            ["MinecraftServer/Players", "SessionDuration", "PlayerName", "*"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Player Session Durations"
          period  = 3600
          stat    = "Average"
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
            ["MinecraftServer/Players", "MonthlyPlaytime", "PlayerId", "*"],
            [".", "MonthlySessions", ".", "*"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Monthly Player Activity"
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
            ["MinecraftServer/Players", "RetentionRate", "CohortWeek", "week1"],
            [".", ".", ".", "week2"],
            [".", ".", ".", "week4"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Player Retention Rates"
          period  = 604800
          stat    = "Average"
          yAxis = {
            left = {
              min = 0
              max = 100
              label = "Retention Rate (%)"
            }
          }
        }
      }
    ]
  })
}

# Activity prediction resources
resource "aws_cloudwatch_event_rule" "activity_prediction" {
  count               = var.enable_monitoring ? 1 : 0
  name                = "${var.name}-activity-prediction"
  description         = "Trigger activity prediction analysis"
  schedule_expression = "cron(0 0 * * ? *)" # Daily at midnight UTC

  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "activity_prediction" {
  count     = var.enable_monitoring ? 1 : 0
  rule      = aws_cloudwatch_event_rule.activity_prediction[0].name
  target_id = "PredictMinecraftActivity"
  arn       = aws_lambda_function.activity_predictor[0].arn

  input = jsonencode({
    instanceId = module.ec2_minecraft.id[0]
  })
}

resource "aws_lambda_function" "activity_predictor" {
  count         = var.enable_monitoring ? 1 : 0
  filename      = "${path.module}/lambda/activity_predictor.zip"
  function_name = "${var.name}-activity-predictor"
  role          = aws_iam_role.activity_predictor[0].arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 300
  memory_size   = 256
  description   = "Predicts peak activity hours and manages server scheduling"

  environment {
    variables = {
      INSTANCE_ID          = module.ec2_minecraft.id[0]
      RETENTION_DAYS       = var.metric_retention_days
      MIN_PLAYER_THRESHOLD = "1"
    }
  }

  tags = local.cost_tags
}

# Allow CloudWatch Events to invoke activity predictor
resource "aws_lambda_permission" "allow_cloudwatch" {
  count         = var.enable_monitoring ? 1 : 0
  statement_id  = "AllowCloudWatchInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.activity_predictor[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.activity_prediction[0].arn
}

# Store prediction configuration
resource "aws_s3_object" "default_peak_hours" {
  count         = var.enable_monitoring ? 1 : 0
  bucket        = local.bucket
  key           = "config/default_peak_hours.json"
  content       = jsonencode({
    peakHours   = var.peak_hours,
    lastUpdated = timestamp()
  })
  content_type  = "application/json"

  lifecycle {
    ignore_changes = [
      content # Ignore changes to content as it's managed by the activity predictor
    ]
  }
}

# IAM role for activity predictor
resource "aws_iam_role" "activity_predictor" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-activity-predictor-role"

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

# IAM policy for activity predictor
resource "aws_iam_role_policy" "activity_predictor" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-activity-predictor-policy"
  role  = aws_iam_role.activity_predictor[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/minecraft/${module.ec2_minecraft.id[0]}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${local.bucket}/config/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StopInstances"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Name" = "${var.name}"
          }
        }
      }
    ]
  })
}
