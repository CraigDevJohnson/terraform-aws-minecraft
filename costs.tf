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


# Budget alerts
resource "aws_budgets_budget" "minecraft" {
  count = var.enable_cost_alerts ? 1 : 0

  name              = "${var.name}-monthly-budget"
  budget_type       = "COST"
  limit_amount      = var.budget_limit
  limit_unit        = "USD"
  time_unit         = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_alert_threshold
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  cost_filter {
    name = "TagKeyValue"
    values = [
      "user:Project$${var.name}",
      "user:Environment$${var.environment}"
    ]
  }
}
