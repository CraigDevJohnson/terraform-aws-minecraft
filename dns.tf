# DNS configuration and health monitoring
# Manages Route53 records and health checks for the Minecraft server

locals {
  health_check_type = var.server_edition == "bedrock" ? "UDP" : "TCP"
  
  # Regional latency mappings and monitoring
  latency_regions = {
    us-west-1 = "US West (N. California)"
    us-east-1 = "US East (N. Virginia)"
    eu-west-1 = "Europe (Ireland)"
  }

  # Latency thresholds (matching Lambda configuration)
  latency_thresholds = {
    warning   = 100  # 100ms triggers warning
    critical  = 200  # 200ms triggers critical alert
  }

  # DNS routing configuration
  dns_routing = var.enable_failover ? "FAILOVER" : (var.enable_latency_routing ? "LATENCY" : "SIMPLE")
}

# Primary DNS record with configurable routing policy
resource "aws_route53_record" "minecraft" {
  count = var.create_dns_record ? 1 : 0

  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = var.dns_ttl

  # Dynamic record configuration based on routing type
  dynamic "failover_routing_policy" {
    for_each = local.dns_routing == "FAILOVER" ? [1] : []
    content {
      type = "PRIMARY"
    }
  }

  dynamic "latency_routing_policy" {
    for_each = local.dns_routing == "LATENCY" ? [1] : []
    content {
      region = data.aws_region.current.name
    }
  }

  set_identifier = local.dns_routing != "SIMPLE" ? "primary" : null
  health_check_id = local.dns_routing != "SIMPLE" ? aws_route53_health_check.minecraft[0].id : null
  records         = [module.ec2_minecraft.public_ip[0]]

  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = var.zone_id != "" && var.domain_name != "" && can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\\.[a-zA-Z]{2,}$", var.domain_name))
      error_message = "Invalid DNS configuration: zone_id and valid domain_name are required when create_dns_record is true"
    }
  }
}

# Secondary DNS record for failover configuration
resource "aws_route53_record" "minecraft_secondary" {
  count = var.create_dns_record && var.enable_failover ? 1 : 0

  zone_id        = var.zone_id
  name           = var.domain_name
  type           = "A"
  set_identifier = "secondary"
  ttl            = var.dns_ttl

  failover_routing_policy {
    type = "SECONDARY"
  }

  health_check_id = aws_route53_health_check.minecraft_secondary[0].id
  records         = [var.secondary_ip]

  lifecycle {
    precondition {
      condition     = var.secondary_ip != ""
      error_message = "secondary_ip must be provided when enable_failover is true"
    }
  }
}

# Primary health check configuration
resource "aws_route53_health_check" "minecraft" {
  count             = var.create_dns_record ? 1 : 0
  fqdn              = var.domain_name
  port              = var.mc_port
  type              = local.health_check_type
  request_interval  = "30"
  failure_threshold = "3"
  measure_latency   = true
  regions          = keys(local.latency_regions)

  tags = merge(local.cost_tags, {
    Name        = "${var.name}-health"
    Environment = var.environment
    ServerType  = var.server_edition
  })
}

# Secondary health check for failover monitoring
resource "aws_route53_health_check" "minecraft_secondary" {
  count             = var.create_dns_record && var.enable_failover ? 1 : 0
  ip_address        = var.secondary_ip
  port              = var.mc_port
  type              = local.health_check_type
  request_interval  = "30"
  failure_threshold = "3"
  measure_latency   = true
  regions          = keys(local.latency_regions)

  tags = merge(local.cost_tags, {
    Name        = "${var.name}-secondary-health"
    Environment = var.environment
    ServerType  = var.server_edition
  })
}

# CloudWatch alarms for DNS health monitoring
resource "aws_cloudwatch_metric_alarm" "dns_health" {
  count               = var.create_dns_record && var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-dns-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = "60"
  statistic           = "Minimum"
  threshold           = "1"
  alarm_description   = "DNS health check status has failed"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.minecraft[0].id
  }

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "dns_health_secondary" {
  count               = var.create_dns_record && var.enable_monitoring && var.enable_failover ? 1 : 0
  alarm_name          = "${var.name}-dns-health-secondary"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = "60"
  statistic           = "Minimum"
  threshold           = "1"
  alarm_description   = "Secondary DNS health check status has failed"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.minecraft_secondary[0].id
  }

  tags = local.cost_tags
}

# Latency monitoring configuration
resource "aws_cloudwatch_metric_alarm" "dns_latency" {
  count               = var.create_dns_record && var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-dns-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "HealthCheckLatency"
  namespace           = "AWS/Route53"
  period              = "300"
  statistic           = "Average"
  threshold           = local.latency_thresholds.critical
  alarm_description   = "DNS health check latency is too high"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.minecraft[0].id
  }

  tags = local.cost_tags
}

# Regional latency monitoring
resource "aws_cloudwatch_metric_alarm" "regional_latency" {
  for_each = var.create_dns_record && var.enable_monitoring ? local.latency_regions : {}

  alarm_name          = "${var.name}-latency-${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "HealthCheckLatency"
  namespace           = "AWS/Route53"
  period              = "300"
  statistic           = "Average"
  threshold           = local.latency_thresholds.critical
  alarm_description   = "DNS health check latency is too high in ${each.value}"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.minecraft[0].id
    Region        = each.key
  }

  tags = merge(local.cost_tags, {
    Region = each.value
  })
}

# Warning-level latency monitoring
resource "aws_cloudwatch_metric_alarm" "regional_latency_warning" {
  for_each = var.create_dns_record && var.enable_monitoring ? local.latency_regions : {}

  alarm_name          = "${var.name}-latency-warning-${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "HealthCheckLatency"
  namespace           = "AWS/Route53"
  period              = "300"
  statistic           = "Average"
  threshold           = local.latency_thresholds.warning
  alarm_description   = "DNS health check latency is approaching high levels in ${each.value}"
  alarm_actions       = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.minecraft[0].id
    Region        = each.key
  }

  tags = merge(local.cost_tags, {
    Region = each.value
  })
}
