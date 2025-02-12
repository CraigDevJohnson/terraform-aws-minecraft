# WAF IP set for blocked addresses
resource "aws_wafv2_ip_set" "minecraft" {
  count              = var.enable_waf ? 1 : 0
  name               = "${var.name}-blocked-ips"
  description        = "IPs blocked due to suspicious activity"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = []

  tags = local.cost_tags
}

# WAF ACL with rate limiting
resource "aws_wafv2_web_acl" "minecraft" {
  count       = var.enable_waf ? 1 : 0
  name        = "${var.name}-protection"
  description = "WAF rules for Minecraft server protection"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

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

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf-overall"
    sampled_requests_enabled   = true
  }

  tags = merge(local.cost_tags, {
    ServerEdition = var.server_edition
    WafRuleSet    = "Enhanced"
  })
}

# WAF monitoring Lambda function
resource "aws_lambda_function" "waf_monitor" {
  count         = var.enable_waf ? 1 : 0
  filename      = "${path.module}/lambda/waf_monitor.zip"
  function_name = "${var.name}-waf-monitor"
  role          = aws_iam_role.waf_monitor[0].arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 60

  environment {
    variables = {
      IP_SET_ID             = aws_wafv2_ip_set.minecraft[0].id
      IP_SET_SCOPE          = "REGIONAL"
      BLOCK_COUNT_THRESHOLD = var.waf_block_count_threshold
    }
  }

  tags = local.cost_tags
}

# WAF monitoring schedule
resource "aws_cloudwatch_event_rule" "waf_monitor" {
  count               = var.enable_waf ? 1 : 0
  name                = "${var.name}-waf-monitor"
  description         = "Trigger WAF monitoring and rate limit adjustment"
  schedule_expression = "rate(1 hour)"

  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "waf_monitor" {
  count     = var.enable_waf ? 1 : 0
  rule      = aws_cloudwatch_event_rule.waf_monitor[0].name
  target_id = "WafMonitorTarget"
  arn       = aws_lambda_function.waf_monitor[0].arn

  input = jsonencode({
    detail = {
      webAclId   = aws_wafv2_web_acl.minecraft[0].id
      webAclName = aws_wafv2_web_acl.minecraft[0].name
    }
  })
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
            ["AWS/WAFv2", "BlockedRequests", "WebACL", aws_wafv2_web_acl.minecraft[0].name],
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
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/WAFV2", "BlockedRequests", "WebACL", aws_wafv2_web_acl.minecraft[0].name, "Rule", "RateBasedProtection"],
            [".", "AllowedRequests", ".", ".", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Rate-Based Protection"
          period  = 300
        }
      }
    ]
  })
}
