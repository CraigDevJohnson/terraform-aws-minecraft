# Status Page Infrastructure
# -------------------------

# Local variables for status page resources
locals {
  status_tags = merge(module.label.tags, {
    Service = "StatusPage"
  })

  # Status page configuration
  status_config = {
    update_frequency = "rate(5 minutes)"
    bucket_suffix    = random_string.s3.result
    log_retention   = var.status_page_log_retention
    waf_settings = {
      rate_limit       = var.waf_rate_limit
      block_threshold  = var.waf_block_threshold
    }
  }
}

# Status page S3 bucket for hosting
resource "aws_s3_bucket" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = "${var.name}-status-${local.status_config.bucket_suffix}"
  tags   = local.status_tags
}

# Enable bucket versioning for recovery
resource "aws_s3_bucket_versioning" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = aws_s3_bucket.status_page[0].id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption for bucket
resource "aws_s3_bucket_server_side_encryption_configuration" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = aws_s3_bucket.status_page[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Configure bucket lifecycle rules
resource "aws_s3_bucket_lifecycle_configuration" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = aws_s3_bucket.status_page[0].id

  rule {
    id     = "cleanup_old_versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Configure bucket for static website hosting
resource "aws_s3_bucket_website_configuration" "status_page" {
  count  = var.enable_status_page ? 1 : 0
  bucket = aws_s3_bucket.status_page[0].id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# Configure bucket access for public reading
resource "aws_s3_bucket_public_access_block" "status_page" {
  count                   = var.enable_status_page ? 1 : 0
  bucket                  = aws_s3_bucket.status_page[0].id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# S3 bucket policy for public read access
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
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.status_page]
}

# Status page updater Lambda function
resource "aws_lambda_function" "status_updater" {
  count         = var.enable_status_page ? 1 : 0
  filename      = "${path.module}/lambda/status_updater.zip"
  function_name = "${var.name}-status-updater"
  role          = aws_iam_role.status_updater[0].arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 30
  memory_size   = 128

  dead_letter_config {
    target_arn = aws_sqs_queue.status_dlq[0].arn
  }

  environment {
    variables = {
      STATUS_BUCKET     = aws_s3_bucket.status_page[0].id
      SERVER_IP        = module.ec2_minecraft.public_ip[0]
      SERVER_PORT      = var.mc_port
      SERVER_TYPE      = var.server_edition
      DOMAIN_NAME      = var.domain_name
      MAX_RETRIES      = "3"
      RETRY_DELAY_MS   = "1000"
      ERROR_THRESHOLD  = "5"
    }
  }

  tags = local.status_tags

  depends_on = [aws_cloudwatch_log_group.status_updater]
}

# CloudWatch Log Group for Lambda function
resource "aws_cloudwatch_log_group" "status_updater" {
  count             = var.enable_status_page ? 1 : 0
  name              = "/aws/lambda/${var.name}-status-updater"
  retention_in_days = 14
  tags              = local.status_tags
}

# IAM role for status updater Lambda
resource "aws_iam_role" "status_updater" {
  count = var.enable_status_page ? 1 : 0
  name  = "${var.name}-status-updater"

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

  tags = local.status_tags
}

# IAM policy for status updater Lambda
resource "aws_iam_role_policy" "status_updater" {
  count = var.enable_status_page ? 1 : 0
  name  = "${var.name}-status-updater-policy"
  role  = aws_iam_role.status_updater[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.status_page[0].arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.status_updater[0].arn}:*"
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
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.status_dlq[0].arn
      }
    ]
  })
}

# CloudWatch Event rule to trigger status updates
resource "aws_cloudwatch_event_rule" "status_update" {
  count               = var.enable_status_page ? 1 : 0
  name                = "${var.name}-status-update"
  description         = "Trigger status page updates every 5 minutes"
  schedule_expression = local.status_config.update_frequency

  tags = local.status_tags
}

# CloudWatch Event target for Lambda function
resource "aws_cloudwatch_event_target" "status_update" {
  count     = var.enable_status_page ? 1 : 0
  rule      = aws_cloudwatch_event_rule.status_update[0].name
  target_id = "UpdateMinecraftStatus"
  arn       = aws_lambda_function.status_updater[0].arn
}

# Lambda permission for CloudWatch Events
resource "aws_lambda_permission" "status_update" {
  count         = var.enable_status_page ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status_updater[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.status_update[0].arn
}

# Add CloudWatch metrics for status page monitoring
resource "aws_cloudwatch_metric_alarm" "status_update_errors" {
  count               = var.enable_status_page ? 1 : 0
  alarm_name          = "${var.name}-status-update-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "Errors"
  namespace          = "AWS/Lambda"
  period             = "300"
  statistic          = "Sum"
  threshold          = "1"
  alarm_description  = "Monitor for status page update errors"
  alarm_actions      = [try(aws_sns_topic.alerts[0].arn, "")]

  dimensions = {
    FunctionName = aws_lambda_function.status_updater[0].function_name
  }

  tags = local.status_tags
}

resource "aws_cloudwatch_dashboard" "status_page" {
  count          = var.enable_status_page ? 1 : 0
  dashboard_name = "${var.name}-status-page"
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
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.status_updater[0].function_name],
            [".", "Errors", ".", "."],
            [".", "Duration", ".", "."]
          ]
          period = 300
          region = data.aws_region.current.name
          title  = "Status Page Updates"
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
            ["AWS/S3", "NumberOfObjects", "BucketName", aws_s3_bucket.status_page[0].id],
            [".", "BucketSizeBytes", ".", "."]
          ]
          period = 3600
          region = data.aws_region.current.name
          title  = "Status Page Storage"
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
            ["AWS/WAFV2", "BlockedRequests", "WebACL", aws_wafv2_web_acl.status_page[0].name, "Rule", "RateLimit"],
            [".", "AllowedRequests", ".", ".", ".", "."]
          ]
          period = 300
          region = data.aws_region.current.name
          title  = "WAF Request Statistics"
        }
      }
    ]
  })
}

# WAF rate limiting for status page
resource "aws_wafv2_web_acl" "status_page" {
  count       = var.enable_status_page ? 1 : 0
  name        = "${var.name}-status-page"
  description = "Rate limiting for status page"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimit"
    priority = 1

    override_action {
      none {}
    }

    statement {
      rate_based_statement {
        limit              = local.status_config.waf_settings.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name               = "StatusPageRateLimit"
      sampled_requests_enabled  = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name               = "StatusPageWebACL"
    sampled_requests_enabled  = true
  }

  tags = local.status_tags
}

# WAF logging configuration
resource "aws_cloudwatch_log_group" "waf_logs" {
  count             = var.enable_status_page ? 1 : 0
  name              = "/aws/wafv2/${var.name}-status-page"
  retention_in_days = local.status_config.log_retention
  tags              = local.status_tags
}

resource "aws_wafv2_web_acl_logging_configuration" "status_page" {
  count                   = var.enable_status_page ? 1 : 0
  log_destination_configs = [aws_cloudwatch_log_group.waf_logs[0].arn]
  resource_arn           = aws_wafv2_web_acl.status_page[0].arn

  logging_filter {
    default_behavior = "KEEP"

    filter {
      behavior = "KEEP"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
      requirement = "MEETS_ANY"
    }
  }
}

# Additional CloudWatch metrics for WAF monitoring
resource "aws_cloudwatch_metric_alarm" "status_page_rate_limit" {
  count               = var.enable_status_page ? 1 : 0
  alarm_name          = "${var.name}-status-page-rate-limit"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period             = "300"
  statistic          = "Sum"
  threshold          = local.status_config.waf_settings.block_threshold
  alarm_description  = "High number of rate-limited requests to status page"
  alarm_actions      = [try(aws_sns_topic.alerts[0].arn, "")]

  dimensions = {
    WebACL = aws_wafv2_web_acl.status_page[0].name
    Rule   = "RateLimit"
  }

  tags = local.status_tags
}

# Dead Letter Queue for failed status updates
resource "aws_sqs_queue" "status_dlq" {
  count = var.enable_status_page ? 1 : 0
  name  = "${var.name}-status-dlq"

  message_retention_seconds = 1209600  # 14 days
  visibility_timeout_seconds = 300     # 5 minutes
  
  tags = local.status_tags
}

# Allow Lambda to use DLQ
resource "aws_sqs_queue_policy" "status_dlq" {
  count     = var.enable_status_page ? 1 : 0
  queue_url = aws_sqs_queue.status_dlq[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.status_dlq[0].arn
      }
    ]
  })
}

# Add CloudWatch alarm for DLQ monitoring
resource "aws_cloudwatch_metric_alarm" "status_dlq" {
  count               = var.enable_status_page ? 1 : 0
  alarm_name          = "${var.name}-status-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period             = "300"
  statistic          = "Average"
  threshold          = "0"
  alarm_description  = "Status page updates appearing in DLQ"
  alarm_actions      = [try(aws_sns_topic.alerts[0].arn, "")]

  dimensions = {
    QueueName = aws_sqs_queue.status_dlq[0].name
  }

  tags = local.status_tags
}
