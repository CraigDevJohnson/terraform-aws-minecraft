# Health monitoring configuration for Minecraft server
# Manages Lambda functions, IAM roles, CloudWatch dashboards, and alarms

# -----------------------------
# Lambda Function Configuration
# -----------------------------
resource "aws_lambda_function" "server_health" {
  count         = var.enable_monitoring ? 1 : 0
  filename      = "${path.module}/lambda/server_health.zip"
  function_name = "${var.name}-server-health"
  role          = aws_iam_role.server_health[0].arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 60
  memory_size   = 256

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.minecraft_alerts[0].arn
    }
  }

  tags = merge(local.cost_tags, {
    Component = "HealthMonitoring"
  })
}

# ----------------------
# IAM Role Configuration
# ----------------------
resource "aws_iam_role" "server_health" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-server-health"

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

# IAM role policy for health monitoring
resource "aws_iam_role_policy" "server_health" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-server-health-policy"
  role  = aws_iam_role.server_health[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
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
          "sns:Publish"
        ]
        Resource = aws_sns_topic.minecraft_alerts[0].arn
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/minecraft/${module.ec2_minecraft.id[0]}/*"
      }
    ]
  })
}

# ------------------------
# CloudWatch Alarms
# ------------------------
resource "aws_cloudwatch_metric_alarm" "low_tps" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-low-tps"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "TPS"
  namespace           = "MinecraftServer/Performance"
  period              = "300"
  statistic           = "Average"
  threshold           = "15"
  alarm_description   = "Server TPS has dropped below acceptable levels"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "high_mspt" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-high-mspt"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "MSPT"
  namespace           = "MinecraftServer/Performance"
  period              = "300"
  statistic           = "Average"
  threshold           = "45"
  alarm_description   = "Server tick processing time is too high"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "high_memory" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "MemoryUsage"
  namespace           = "MinecraftServer"
  period              = "300"
  statistic           = "Average"
  threshold           = "85"
  alarm_description   = "Server memory usage is too high"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  tags = local.cost_tags
}

# -----------------------
# CloudWatch Dashboards
# -----------------------
resource "aws_cloudwatch_dashboard" "server_health" {
  count          = var.enable_monitoring ? 1 : 0
  dashboard_name = "${var.name}-server-health"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer/Performance", "TPS", "InstanceId", module.ec2_minecraft.id[0]],
            [".", "MSPT", ".", "."]
          ]
          view   = "timeSeries"
          region = data.aws_region.current.name
          title  = "Server Performance"
          period = 60
          yAxis = {
            left : {
              min : 0,
              max : 20
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer", "CPUUsage", "InstanceId", module.ec2_minecraft.id[0]],
            [".", "MemoryUsage", ".", "."]
          ]
          view   = "timeSeries"
          region = data.aws_region.current.name
          title  = "Resource Usage"
          period = 60
          yAxis = {
            left : {
              min : 0,
              max : 100
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer", "ChunkLoadTime", "InstanceId", module.ec2_minecraft.id[0]],
            [".", "WorldSize", ".", "."]
          ]
          view   = "timeSeries"
          region = data.aws_region.current.name
          title  = "World Metrics"
          period = 300
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          alarms = [
            aws_cloudwatch_metric_alarm.low_tps[0].arn,
            aws_cloudwatch_metric_alarm.high_mspt[0].arn,
            aws_cloudwatch_metric_alarm.high_memory[0].arn
          ]
          title  = "Server Health Alarms"
          region = data.aws_region.current.name
        }
      }
    ]
  })
}

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
            ["MinecraftServer/PlayerStats", "MonthlyPlaytime", "PlayerId", "*"]
          ]
          view    = "timeSeries"
          stacked = true
          region  = data.aws_region.current.name
          title   = "Monthly Playtime by Player"
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
            ["MinecraftServer/PlayerStats", "MonthlySessions", "PlayerId", "*"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Monthly Sessions by Player"
          period  = 86400
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer", "UniquePlayerCount", "InstanceId", module.ec2_minecraft.id[0]],
            [".", "ReturnPlayerCount", ".", "."],
            [".", "NewPlayerCount", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Player Demographics"
          period  = 3600
        }
      }
    ]
  })
}

# ---------------------
# Event Rules
# ---------------------
resource "aws_cloudwatch_event_rule" "health_check" {
  count               = var.enable_monitoring ? 1 : 0
  name                = "${var.name}-health-check"
  description         = "Trigger server health monitoring"
  schedule_expression = "rate(1 minute)"

  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "health_check" {
  count     = var.enable_monitoring ? 1 : 0
  rule      = aws_cloudwatch_event_rule.health_check[0].name
  target_id = "ServerHealthCheck"
  arn       = aws_lambda_function.server_health[0].arn
}

resource "aws_lambda_permission" "health_check" {
  count         = var.enable_monitoring ? 1 : 0
  statement_id  = "AllowEventBridgeInvokeHealthCheck"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.server_health[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_check[0].arn
}
