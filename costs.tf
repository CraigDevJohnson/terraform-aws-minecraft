# Core cost management tags for better tracking
locals {
  cost_tags = {
    Project     = var.name
    Environment = var.environment
    CostCenter  = "Gaming"
    ServerType  = var.server_edition
    Managed     = "Terraform"
  }
}

# Core cost management configuration
# AWS Budget and cost allocation management

# Cost monitoring and allocation resources
resource "aws_budgets_budget" "minecraft" {
  count = var.enable_cost_alerts ? 1 : 0

  name         = "${var.name}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Actual spend notification
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_alert_threshold
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Forecasted spend notification
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Cost filters
  cost_filter {
    name = "Service"
    values = [
      "Amazon Elastic Compute Cloud - Compute",
      "AWS Lambda",
      "Amazon Simple Storage Service",
      "AWS Backup",
      "Amazon CloudWatch",
      "AWS WAF"
    ]
  }

  cost_filter {
    name = "TagKeyValue"
    values = [
      "user:Project$${var.name}",
      "user:Environment$${var.environment}",
      "user:CostCenter$Gaming",
      "user:ServerType$${var.server_edition}"
    ]
  }

  cost_types {
    include_credit       = true
    include_discount     = true
    include_other       = true
    include_recurring   = true
    include_refund      = true
    include_subscription = true
    include_support     = false
    include_tax         = true
    include_upfront     = true
    use_amortized      = false
    use_blended        = false
  }
}

# Cost monitoring dashboard
resource "aws_cloudwatch_dashboard" "cost_monitoring" {
  count          = var.enable_cost_alerts ? 1 : 0
  dashboard_name = "${var.name}-cost-monitoring"

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
            ["AWS/Billing", "EstimatedCharges", "ServiceName", "AmazonEC2"],
            [".", ".", ".", "AWSLambda"],
            [".", ".", ".", "AWSBackup"],
            [".", ".", ".", "AmazonCloudWatch"],
            [".", ".", ".", "AWSWAF"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "Estimated Service Charges"
          period  = 21600  # 6 hours
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
            ["AWS/Billing", "EstimatedCharges", "Currency", "USD"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "Total Estimated Charges"
          period  = 21600
        }
      }
    ]
  })
}

# Cost anomaly detection
resource "aws_ce_anomaly_monitor" "cost_monitoring" {
  count      = var.enable_cost_alerts ? 1 : 0
  name       = "${var.name}-cost-anomalies"
  monitor_type = "DIMENSIONAL"

  monitor_dimension {
    dimension_name = "SERVICE"
    dimension_values = [
      "Amazon Elastic Compute Cloud - Compute",
      "AWS Lambda",
      "Amazon Simple Storage Service",
      "AWS Backup",
      "Amazon CloudWatch",
      "AWS WAF"
    ]
  }
}

resource "aws_ce_anomaly_subscription" "cost_alerts" {
  count             = var.enable_cost_alerts ? 1 : 0
  name              = "${var.name}-cost-anomaly-subscription"
  threshold         = 10
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.cost_monitoring[0].arn]

  subscriber {
    type     = "EMAIL"
    address  = join(",", var.budget_alert_emails)
  }
}

# Cost optimization recommendations
resource "aws_s3_bucket_analytics_configuration" "cost_analysis" {
  count  = var.enable_cost_alerts ? 1 : 0
  bucket = local.bucket
  name   = "CostOptimization"

  storage_class_analysis {
    data_export {
      destination {
        s3_bucket_destination {
          bucket_arn = local.bucket
          prefix     = "cost-analysis"
        }
      }
    }
  }
}

resource "aws_s3_bucket_metric" "cost_metrics" {
  count  = var.enable_cost_alerts ? 1 : 0
  bucket = local.bucket
  name   = "StorageCostMetrics"

  filter {
    prefix = "backups/"
  }
}
