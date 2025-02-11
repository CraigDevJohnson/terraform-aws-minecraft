# CloudWatch Metrics Dashboard
resource "aws_cloudwatch_dashboard" "minecraft_metrics" {
  dashboard_name = "${var.name}-monitoring"

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
            ["MinecraftServer", "PlayerCount", "InstanceId", module.ec2_minecraft.id[0]],
            [".", "CPUCreditBalance", ".", "."],
            [".", "MemoryUsage", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Server Resources"
          period  = 60
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
            ["MinecraftServer/Network", "RegionalLatency", "InstanceId", module.ec2_minecraft.id[0], "Region", "us-east-1"],
            ["...", ".", ".", ".", ".", "eu-west-1"],
            ["...", ".", ".", ".", ".", "ap-southeast-1"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Regional Latency"
          period  = 60
        }
      }
    ]
  })
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "cpu_credits" {
  alarm_name          = "${var.name}-cpu-credits-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUCreditBalance"
  namespace           = "AWS/EC2"
  period             = "300"
  statistic          = "Average"
  threshold          = "20"
  alarm_description  = "CPU credit balance is too low"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "memory_usage" {
  alarm_name          = "${var.name}-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period             = "300"
  statistic          = "Average"
  threshold          = "85"
  alarm_description  = "Memory usage is too high"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "network_out" {
  alarm_name          = "${var.name}-network-spike"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "NetworkOut"
  namespace           = "AWS/EC2"
  period             = "300"
  statistic          = "Average"
  threshold          = "5000000" # 5 MB/s
  alarm_description  = "Network traffic spike detected"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }

  tags = local.cost_tags
}

# SNS Topics for Alerts
resource "aws_sns_topic" "minecraft_alerts" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-alerts"
  tags  = local.cost_tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.enable_monitoring && var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.minecraft_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# CloudWatch Agent Configuration
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

// CloudWatch Dashboard for server monitoring
resource "aws_cloudwatch_dashboard" "minecraft_metrics" {
  dashboard_name = "${var.name}-monitoring"

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
            ["MinecraftServer", "PlayerCount", "InstanceId", module.ec2_minecraft.id[0]],
            [".", "CPUCreditBalance", ".", "."],
            [".", "MemoryUsage", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Server Resources"
          period  = 60
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
            ["MinecraftServer/Network", "RegionalLatency", "InstanceId", module.ec2_minecraft.id[0], "Region", "us-east-1"],
            ["...", ".", ".", ".", ".", "eu-west-1"],
            ["...", ".", ".", ".", ".", "ap-southeast-1"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Regional Latency"
          period  = 60
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
            ["MinecraftServer/Performance", "TPS"],
            [".", "MSPT"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Server Performance"
          period  = 60
          yAxis = {
            left: {
              min: 0,
              max: 20
            }
          }
        }
      }
    ]
  })
}

// CloudWatch Alarms for the new metrics
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.name}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUsage"
  namespace           = "MinecraftServer"
  period             = "300"
  statistic          = "Average"
  threshold          = "80"
  alarm_description  = "CPU usage exceeded 80%"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }
}

resource "aws_cloudwatch_metric_alarm" "high_memory" {
  alarm_name          = "${var.name}-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "MemoryUsage"
  namespace           = "MinecraftServer"
  period             = "300"
  statistic          = "Average"
  threshold          = "85"
  alarm_description  = "Memory usage exceeded 85%"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }
}

resource "aws_cloudwatch_metric_alarm" "no_players" {
  alarm_name          = "${var.name}-no-players"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "6"
  metric_name         = "PlayerCount"
  namespace           = "MinecraftServer"
  period             = "300"
  statistic          = "Maximum"
  threshold          = "1"
  alarm_description  = "No players connected for 30 minutes"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
    ServerType = var.server_edition
  }
}

// SNS Topic for alarms
resource "aws_sns_topic" "minecraft_alerts" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-alerts"
  tags  = local.cost_tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.enable_monitoring && var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.minecraft_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

// Schedule and resources for activity prediction
resource "aws_cloudwatch_event_rule" "activity_prediction" {
  count               = var.enable_monitoring ? 1 : 0
  name                = "${var.name}-activity-prediction"
  description         = "Trigger activity prediction analysis"
  schedule_expression = "cron(0 0 * * ? *)"  // Run daily at midnight UTC

  tags = local.cost_tags
}

// Status page bucket for server monitoring
resource "aws_s3_bucket" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = "${var.name}-status-${random_string.s3.result}"
  
  tags = merge(local.cost_tags, {
    Purpose = "Server Status Page"
  })
}

resource "aws_s3_bucket_website_configuration" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = aws_s3_bucket.status_page[0].id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = aws_s3_bucket.status_page[0].id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = aws_s3_bucket.status_page[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.status_page[0].arn}/*"
      },
    ]
  })
}

// CloudWatch Alarms for monitoring
resource "aws_cloudwatch_metric_alarm" "cpu_credits" {
  alarm_name          = "${module.label.id}-cpu-credits-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "CPUCreditBalance"
  namespace          = "AWS/EC2"
  period             = "300"
  statistic          = "Average"
  threshold          = "20"
  alarm_description  = "CPU credit balance is too low"
  alarm_actions      = []  // Add SNS topic ARN here if needed

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }

  tags = module.label.tags
}

resource "aws_cloudwatch_metric_alarm" "memory_usage" {
  alarm_name          = "${module.label.id}-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "mem_used_percent"
  namespace          = "CWAgent"
  period             = "300"
  statistic          = "Average"
  threshold          = "85"
  alarm_description  = "Memory usage is too high"
  alarm_actions      = []  // Add SNS topic ARN here if needed

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }

  tags = module.label.tags
}

resource "aws_cloudwatch_metric_alarm" "network_out" {
  alarm_name          = "${module.label.id}-network-spike"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "NetworkOut"
  namespace          = "AWS/EC2"
  period             = "300"
  statistic          = "Average"
  threshold          = "5000000" // 5 MB/s
  alarm_description  = "Network traffic spike detected"
  alarm_actions      = []  // Add SNS topic ARN here if needed

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }

  tags = module.label.tags
}