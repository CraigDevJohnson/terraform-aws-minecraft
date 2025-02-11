# DNS Record for the Minecraft server
resource "aws_route53_record" "minecraft" {
  count = var.create_dns_record ? 1 : 0

  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = var.dns_ttl
  records = [module.ec2_minecraft.public_ip[0]]

  lifecycle {
    create_before_destroy = true
  }
}

# DNS validation
locals {
  validate_dns_config = var.create_dns_record && (var.zone_id == "" || var.domain_name == "") ? file("ERROR: When create_dns_record is true, both zone_id and domain_name must be provided") : null
}

# Health check for DNS failover
resource "aws_route53_health_check" "minecraft" {
  count             = var.create_dns_record ? 1 : 0
  fqdn              = var.domain_name
  port              = var.mc_port
  type             = "TCP"
  request_interval = "30"
  failure_threshold = "3"

  tags = merge(local.cost_tags, {
    Name = "${var.name}-health"
  })
}
