# Network Data Sources
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = local.vpc_id
}

# Network Locals
locals {
  vpc_id    = length(var.vpc_id) > 0 ? var.vpc_id : data.aws_vpc.default.id
  subnet_id = length(var.subnet_id) > 0 ? var.subnet_id : sort(data.aws_subnet_ids.default.ids)[0]
}

// VPC Endpoints
resource "aws_vpc_endpoint" "ssm" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type = "Interface"

  security_group_ids = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true
  tags               = module.label.tags
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type = "Interface"

  security_group_ids = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true
  tags               = module.label.tags
}

resource "aws_vpc_endpoint" "ec2messages" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type = "Interface"

  security_group_ids = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true
  tags               = module.label.tags
}

// Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoint" {
  name        = "${var.name}-vpc-endpoint-sg"
  description = "Security group for VPC endpoints"
  vpc_id      = local.vpc_id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [module.ec2_security_group.security_group_id]
    description     = "Allow HTTPS from Minecraft server"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(module.label.tags, {
    Name = "${var.name}-vpc-endpoint"
  })
}

// Security Group
module "ec2_security_group" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-security-group.git?ref=master"

  name        = "${var.name}-ec2"
  description = "Allow game ports for Minecraft server"
  vpc_id      = local.vpc_id

  ingress_rules = []
  
  ingress_with_cidr_blocks = [
    {
      from_port   = var.mc_port
      to_port     = var.mc_port
      protocol    = var.server_edition == "bedrock" ? "udp" : "tcp"
      description = "Minecraft ${var.server_edition} access"
      cidr_blocks = join(",", var.allowed_cidrs)
    }
  ]

  egress_rules = ["all-all"]

  tags = merge(module.label.tags, {
    ServerEdition = var.server_edition
    ManagedBy = "terraform"
  })
}

// Add S3 VPC endpoint for improved performance
resource "aws_vpc_endpoint" "s3" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = data.aws_vpc.default.main_route_table_id
  
  tags = merge(module.label.tags, {
    Name = "${var.name}-s3-endpoint"
  })
}

// Add Route53 health check
resource "aws_route53_health_check" "server" {
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

// Flow logs for network monitoring
resource "aws_flow_log" "minecraft" {
  count                = var.enable_monitoring ? 1 : 0
  iam_role_arn        = aws_iam_role.flow_logs[0].arn
  log_destination     = aws_cloudwatch_log_group.flow_logs[0].arn
  traffic_type        = "ALL"
  vpc_id              = local.vpc_id
  log_format         = "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status}"

  tags = merge(local.cost_tags, {
    Name = "${var.name}-flow-logs"
  })
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_monitoring ? 1 : 0
  name              = "/aws/vpc/flow-logs/${var.name}"
  retention_in_days = 7

  tags = local.cost_tags
}
