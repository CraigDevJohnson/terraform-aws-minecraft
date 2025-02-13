# WAF Configuration for Minecraft Server
# --------------------------------------------

locals {
  waf_tags = merge(local.cost_tags, {
    Service     = "WAF"
    RuleSet     = "Enhanced"
    Environment = var.environment
  })
}

# WAF IP set for blocked addresses
resource "aws_wafv2_ip_set" "minecraft" {
  count              = var.enable_waf ? 1 : 0
  name               = "${var.name}-blocked-ips"
  description        = "IPs blocked due to suspicious activity"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = []

  tags = local.waf_tags
}

# WAF ACL with rate limiting and auto-adjustment
resource "aws_wafv2_web_acl" "minecraft" {
  count       = var.enable_waf ? 1 : 0
  name        = "${var.name}-protection"
  description = "WAF rules for Minecraft server protection"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Rate-based protection with auto-adjustment
  rule {
    name     = "RateBasedProtection"
    priority = 1

    override_action {
      none {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rules.rate_limit.limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # IP reputation check
  dynamic "rule" {
    for_each = var.waf_rules.ip_reputation.enabled ? [1] : []
    content {
      name     = "IPReputationLists"
      priority = 2

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = "AWSManagedRulesAmazonIpReputationList"
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-ip-reputation"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf-overall"
    sampled_requests_enabled   = true
  }

  tags = local.waf_tags
}

# WAF monitoring Lambda function using consolidated monitoring role
resource "aws_lambda_function" "waf_monitor" {
  count         = var.enable_waf ? 1 : 0
  filename      = "${path.module}/lambda/waf_monitor.zip"
  function_name = "${var.name}-waf-monitor"
  role          = aws_iam_role.lambda_monitoring.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 60
  memory_size   = 256

  environment {
    variables = {
      IP_SET_ID             = aws_wafv2_ip_set.minecraft[0].id
      IP_SET_NAME          = aws_wafv2_ip_set.minecraft[0].name
      IP_SET_SCOPE         = "REGIONAL"
      WEB_ACL_ID           = aws_wafv2_web_acl.minecraft[0].id
      WEB_ACL_NAME         = aws_wafv2_web_acl.minecraft[0].name
      BLOCK_COUNT_THRESHOLD = tostring(var.waf_block_count_threshold)
    }
  }

  tags = local.waf_tags

  depends_on = [aws_cloudwatch_log_group.waf_monitor]
}

# WAF monitoring CloudWatch resources
resource "aws_cloudwatch_log_group" "waf_monitor" {
  count             = var.enable_waf ? 1 : 0
  name              = "/aws/lambda/${var.name}-waf-monitor"
  retention_in_days = var.log_retention_days
  tags              = local.waf_tags
}

resource "aws_cloudwatch_event_rule" "waf_monitor" {
  count               = var.enable_waf ? 1 : 0
  name                = "${var.name}-waf-monitor"
  description         = "Trigger WAF monitoring and rate limit adjustment"
  schedule_expression = "rate(1 hour)"
  tags                = local.waf_tags
}

resource "aws_cloudwatch_event_target" "waf_monitor" {
  count     = var.enable_waf ? 1 : 0
  rule      = aws_cloudwatch_event_rule.waf_monitor[0].name
  target_id = "WafMonitorTarget"
  arn       = aws_lambda_function.waf_monitor[0].arn
}

resource "aws_lambda_permission" "waf_monitor" {
  count         = var.enable_waf ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.waf_monitor[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.waf_monitor[0].arn
}

# WAF monitoring dashboard
resource "aws_cloudwatch_dashboard" "waf_monitoring" {
  count          = var.enable_waf ? 1 : 0
  dashboard_name = "${var.name}-waf-monitoring"

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
            ["AWS/WAFV2", "BlockedRequests", "WebACL", aws_wafv2_web_acl.minecraft[0].name],
            [".", "AllowedRequests", ".", "."],
            [".", "PassedRequests", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "WAF Request Statistics"
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
            ["MinecraftServer/WAF", "BlockedIPCount"],
            [".", "BlockedRequestsRate"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "WAF Protection Metrics"
          period  = 300
        }
      }
    ]
  })
}
