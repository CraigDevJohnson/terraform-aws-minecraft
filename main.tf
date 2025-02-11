// This module creates a single EC2 instance for running a Minecraft server

// Default network
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = local.vpc_id
}

data "aws_caller_identity" "aws" {}

locals {
  vpc_id    = length(var.vpc_id) > 0 ? var.vpc_id : data.aws_vpc.default.id
  subnet_id = length(var.subnet_id) > 0 ? var.subnet_id : sort(data.aws_subnet_ids.default.ids)[0]
  tf_tags = {
    Terraform   = "true"
    Environment = var.environment
    Project     = var.name
  }
}

// Keep labels, tags consistent
module "label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=master"

  namespace   = var.namespace
  stage       = var.environment
  name        = var.name
  delimiter   = "-"
  label_order = ["environment", "stage", "name", "attributes"]
  tags        = merge(var.tags, local.tf_tags)
}

// Amazon Linux2 AMI - can switch this to default by editing the EC2 resource below
data "aws_ami" "amazon-linux-2" {
  most_recent = true

  owners = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*"]
  }
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

// Amazon Linux 2023 AMI
data "aws_ami" "amazon-linux-2023" {
  most_recent = true

  owners = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "name"
    values = ["al2023-ami-minimal-*-x86_64"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

// Find latest Ubuntu AMI, use as default if no AMI specified
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] // Canonical
}

// S3 bucket for persisting minecraft
resource "random_string" "s3" {
  length  = 12
  special = false
  upper   = false
}

#data "aws_s3_bucket" "selected" {
#  bucket = local.bucket
#}

locals {
  using_existing_bucket = signum(length(var.bucket_name)) == 1

  bucket = length(var.bucket_name) > 0 ? var.bucket_name : "${module.label.id}-${random_string.s3.result}"
}

module "s3" {
  source = "terraform-aws-modules/s3-bucket/aws"

  create_bucket = local.using_existing_bucket ? false : true

  bucket = local.bucket
  acl    = "private"

  force_destroy = var.bucket_force_destroy

  versioning = {
    enabled = var.enable_versioning
    mfa_delete = false
  }

  # S3 bucket-level Public Access Block configuration
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # Lifecycle rules for cost optimization
  lifecycle_rule = [
    {
      id      = "backup-lifecycle"
      enabled = true

      transition = [
        {
          days          = 30
          storage_class = "STANDARD_IA"
        },
        {
          days          = 90
          storage_class = "GLACIER"
        }
      ]

      expiration = {
        days = 365  # Expire old backups after 1 year
      }
    }
  ]

  tags = merge(module.label.tags, local.cost_tags)
}

// IAM role for S3 access
resource "aws_iam_role" "allow_s3" {
  name   = "${module.label.id}-allow-ec2-to-s3"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "mc" {
  name = "${module.label.id}-instance-profile"
  role = aws_iam_role.allow_s3.name
}

resource "aws_iam_role_policy" "mc_allow_ec2_to_s3" {
  name   = "${module.label.id}-allow-ec2-to-s3"
  role   = aws_iam_role.allow_s3.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ],
        Resource = [module.s3.s3_bucket_arn]
      },
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource = ["${module.s3.s3_bucket_arn}/*"]
      }
    ]
  })
}

// Add Lambda IAM role for server management
resource "aws_iam_role" "lambda_role" {
  name = "${module.label.id}-lambda-manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_ec2_policy" {
  name = "${module.label.id}-lambda-ec2-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:DescribeInstances",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData",
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:SendCommand"
        ]
        Resource = ["*"]
      }
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
  alarm_actions      = []  # Add SNS topic ARN here if needed

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
  alarm_actions      = []  # Add SNS topic ARN here if needed

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
  alarm_actions      = []  # Add SNS topic ARN here if needed

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }

  tags = module.label.tags
}

// CloudWatch Agent IAM role policy
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

// Systems Manager IAM role policy
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

// VPC Endpoint for Systems Manager
resource "aws_vpc_endpoint" "ssm" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type = "Interface"

  security_group_ids = [
    aws_security_group.vpc_endpoint.id
  ]

  private_dns_enabled = true
  tags               = module.label.tags
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type = "Interface"

  security_group_ids = [
    aws_security_group.vpc_endpoint.id
  ]

  private_dns_enabled = true
  tags               = module.label.tags
}

resource "aws_vpc_endpoint" "ec2messages" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.ec2messages"
  vpc_endpoint_type = "Interface"

  security_group_ids = [
    aws_security_group.vpc_endpoint.id
  ]

  private_dns_enabled = true
  tags               = module.label.tags
}

// Add security group for VPC endpoints
resource "aws_security_group" "vpc_endpoint" {
  name        = "${var.name}-vpc-endpoint-sg"
  description = "Security group for VPC endpoints"
  vpc_id      = local.vpc_id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [module.ec2_security_group.this_security_group_id]
  }

  tags = merge(module.label.tags, {
    Name = "${var.name}-vpc-endpoint"
  })
}

// Get current region
data "aws_region" "current" {}

// Script to configure the server - this is where most of the magic occurs!
data "template_file" "user_data" {
  template = file("${path.module}/user_data.sh")

  vars = {
    mc_root        = var.mc_root
    mc_bucket      = local.bucket
    mc_backup_freq = var.mc_backup_freq
    mc_version     = var.mc_version
    mc_type        = var.mc_type   
    java_mx_mem    = var.java_mx_mem
    java_ms_mem    = var.java_ms_mem
  }
}

// Security group for our instance - allows SSH and minecraft 
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

// Create EC2 ssh key pair
resource "tls_private_key" "ec2_ssh" {
  count = length(var.key_name) > 0 ? 0 : 1

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2_ssh" {
  count = length(var.key_name) > 0 ? 0 : 1

  key_name   = "${var.name}-ec2-ssh-key"
  public_key = tls_private_key.ec2_ssh[0].public_key_openssh
}

locals {
  _ssh_key_name = length(var.key_name) > 0 ? var.key_name : aws_key_pair.ec2_ssh[0].key_name
}

// EC2 instance for the server - tune instance_type to fit your performance and budget requirements
locals {
  instance_tags = merge(module.label.tags, {
    AutoShutdown = var.enable_auto_shutdown
    ActiveHoursStart = var.active_hours_start
    ActiveHoursEnd = var.active_hours_end
    MinPlayersToStart = var.min_players_to_start
    ServerEdition = var.server_edition
    DNSName = var.create_dns_record ? var.domain_name : "none"
  })
}

module "ec2_minecraft" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ec2-instance.git?ref=master"
  name   = "${var.name}-public"

  # instance
  key_name             = local._ssh_key_name
  ami                  = var.ami != "" ? var.ami : data.aws_ami.amazon-linux-2023.id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.mc.id
  user_data            = data.template_file.user_data.rendered

  # network
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [ module.ec2_security_group.this_security_group_id ]
  associate_public_ip_address = var.associate_public_ip_address

  tags = merge(local.instance_tags, local.cost_tags)
}

// Add EBS volume configuration with optimized settings
resource "aws_ebs_volume" "minecraft" {
  availability_zone = module.ec2_minecraft.availability_zone[0]
  size             = 30
  type             = "gp3"
  iops            = 3000
  throughput      = 125

  encrypted = true

  tags = merge(local.cost_tags, {
    Name = "${var.name}-minecraft-data"
  })

  lifecycle {
    prevent_destroy = true  // Prevent accidental deletion of game data
  }
}

resource "aws_volume_attachment" "minecraft" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.minecraft.id
  instance_id = module.ec2_minecraft.id[0]
}

// Add automated snapshot management
resource "aws_dlm_lifecycle_policy" "minecraft" {
  description        = "Minecraft server volume backup policy"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state             = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "Daily snapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times        = ["23:00"]
      }

      retain_rule {
        count = 7  // Keep last 7 daily snapshots
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = true
    }

    target_tags = {
      Name = "${var.name}-minecraft-data"
    }
  }

  tags = local.cost_tags
}

// IAM role for DLM
resource "aws_iam_role" "dlm_lifecycle_role" {
  name = "${var.name}-dlm-lifecycle-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "dlm.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "dlm_lifecycle" {
  name = "${var.name}-dlm-lifecycle-policy"
  role = aws_iam_role.dlm_lifecycle_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateSnapshot",
          "ec2:CreateSnapshots",
          "ec2:DeleteSnapshot",
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:*::snapshot/*"
      }
    ]
  })
}

// DNS Record for the Minecraft server
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

// Add DNS validation to domain name variable
locals {
  validate_dns_config = var.create_dns_record && (var.zone_id == "" || var.domain_name == "") ? file("ERROR: When create_dns_record is true, both zone_id and domain_name must be provided") : null
}

// Add cost allocation tags for better tracking
locals {
  cost_tags = {
    Project     = var.name
    Environment = var.environment
    CostCenter  = "Gaming"
    ServerType  = var.server_edition
    Managed     = "Terraform"
  }
}

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

// Lambda function for updating status page
resource "aws_lambda_function" "status_updater" {
  count         = var.enable_status_page ? 1 : 0
  filename      = "${path.module}/lambda/status_updater.zip"
  function_name = "${var.name}-status-updater"
  role         = aws_iam_role.lambda_status_updater[0].arn
  handler      = "index.handler"
  runtime      = "nodejs18.x"
  timeout      = 30

  environment {
    variables = {
      STATUS_BUCKET = aws_s3_bucket.status_page[0].id
      SERVER_IP     = module.ec2_minecraft.public_ip[0]
      SERVER_PORT   = var.mc_port
      SERVER_TYPE   = var.server_edition
      DOMAIN_NAME   = var.domain_name
    }
  }

  tags = local.cost_tags
}

resource "aws_iam_role" "lambda_status_updater" {
  count = var.enable_status_page ? 1 : 0
  name  = "${var.name}-status-updater-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_status_updater" {
  count = var.enable_status_page ? 1 : 0
  name  = "${var.name}-status-updater-policy"
  role  = aws_iam_role.lambda_status_updater[0].id

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
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

// CloudWatch Event to trigger status updates
resource "aws_cloudwatch_event_rule" "status_update" {
  count               = var.enable_status_page ? 1 : 0
  name                = "${var.name}-status-update"
  description         = "Trigger Minecraft server status page updates"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "status_update" {
  count     = var.enable_status_page ? 1 : 0
  rule      = aws_cloudwatch_event_rule.status_update[0].name
  target_id = "UpdateMinecraftStatus"
  arn       = aws_lambda_function.status_updater[0].arn
}

resource "aws_lambda_permission" "status_update" {
  count         = var.enable_status_page ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status_updater[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.status_update[0].arn
}

// WAF Configuration for DDoS protection
resource "aws_wafv2_ip_set" "minecraft" {
  count              = var.enable_waf ? 1 : 0
  name               = "${var.name}-blocked-ips"
  description        = "IPs blocked due to suspicious activity"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = []

  tags = local.cost_tags
}

resource "aws_wafv2_web_acl" "minecraft" {
  count       = var.enable_waf ? 1 : 0
  name        = "${var.name}-protection"
  description = "WAF rules for Minecraft server protection"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Rate limiting rule
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
      metric_name               = "${var.name}-rate-limit"
      sampled_requests_enabled  = true
    }
  }

  # Protocol enforcement
  rule {
    name     = "MinecraftProtocol"
    priority = 2

    override_action {
      none {}
    }

    statement {
      byte_match_statement {
        search_string = var.server_edition == "bedrock" ? "MCPE" : "MC|"
        positional_constraint = "STARTS_WITH"
        field_to_match {
          body {}
        }
        text_transformation {
          priority = 1
          type     = "NONE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name               = "${var.name}-protocol-validation"
      sampled_requests_enabled  = true
    }
  }

  # IP Reputation rule
  rule {
    name     = "IPReputation"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesATPRuleSet"
        vendor_name = "AWS"

        rule_action_override {
          action_to_use {
            block {}
          }
          name = "BlockHighRiskRequests"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name               = "${var.name}-ip-reputation"
      sampled_requests_enabled  = true
    }
  }

  # Known attack patterns
  rule {
    name     = "CommonAttackProtection"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name               = "${var.name}-common-attacks"
      sampled_requests_enabled  = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name               = "${var.name}-waf-overall"
    sampled_requests_enabled  = true
  }

  tags = merge(local.cost_tags, {
    ServerEdition = var.server_edition
    WafRuleSet    = "Enhanced"
  })
}

// Add metrics dashboard for WAF monitoring
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
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/WAFv2", "RateBasedRuleMatches", "WebACL", aws_wafv2_web_acl.minecraft[0].name, "Rule", "RateBasedProtection"],
            [".", "ProtocolRuleMatches", ".", ".", ".", "MinecraftProtocol"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Rule Match Statistics"
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
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/WAFV2", "BlockedRequests", "WebACL", aws_wafv2_web_acl.minecraft[0].name, "Rule", "MinecraftProtocol"],
            [".", "AllowedRequests", ".", ".", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Protocol Validation"
          period  = 300
          annotations = {
            horizontal: [{
              value: 100,
              label: "Alert Threshold",
              color: "#ff0000"
            }]
          }
        }
      }
    ]
  })
}

// Lambda function to monitor WAF logs and update blocked IPs
resource "aws_lambda_function" "waf_monitor" {
  count         = var.enable_waf ? 1 : 0
  filename      = "${path.module}/lambda/waf_monitor.zip"
  function_name = "${var.name}-waf-monitor"
  role         = aws_iam_role.waf_monitor[0].arn
  handler      = "index.handler"
  runtime      = "nodejs18.x"
  timeout      = 60

  environment {
    variables = {
      IP_SET_ID = aws_wafv2_ip_set.minecraft[0].id
      IP_SET_SCOPE = "REGIONAL"
      BLOCK_COUNT_THRESHOLD = var.waf_block_count_threshold
    }
  }

  tags = local.cost_tags
}

resource "aws_iam_role" "waf_monitor" {
  count = var.enable_waf ? 1 : 0
  name  = "${var.name}-waf-monitor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "waf_monitor" {
  count = var.enable_waf ? 1 : 0
  name  = "${var.name}-waf-monitor-policy"
  role  = aws_iam_role.waf_monitor[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "wafv2:GetIPSet",
          "wafv2:UpdateIPSet",
          "wafv2:GetWebACL",
          "wafv2:GetSampledRequests"
        ]
        Resource = [
          aws_wafv2_ip_set.minecraft[0].arn,
          aws_wafv2_web_acl.minecraft[0].arn
        ]
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
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

// Schedule for WAF monitoring
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
      webAclId = aws_wafv2_web_acl.minecraft[0].id
      webAclName = aws_wafv2_web_acl.minecraft[0].name
    }
  })
}

resource "aws_lambda_permission" "waf_monitor" {
  count         = var.enable_waf ? 1 : 0
  statement_id  = "AllowEventBridgeInvokeWafMonitor"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.waf_monitor[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.waf_monitor[0].arn
}

// Version checker resources
resource "aws_sns_topic" "minecraft_updates" {
  count = var.enable_auto_updates ? 1 : 0
  name  = "${var.name}-server-updates"
  tags  = local.cost_tags
}

resource "aws_sns_topic_subscription" "updates_email" {
  count     = var.enable_auto_updates && var.update_notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.minecraft_updates[0].arn
  protocol  = "email"
  endpoint  = var.update_notification_email
}

resource "aws_lambda_function" "version_checker" {
  count         = var.enable_auto_updates ? 1 : 0
  filename      = "${path.module}/lambda/version_checker.zip"
  function_name = "${var.name}-version-checker"
  role         = aws_iam_role.version_checker[0].arn
  handler      = "index.handler"
  runtime      = "nodejs18.x"
  timeout      = 60

  environment {
    variables = {
      INSTANCE_ID = module.ec2_minecraft.id[0]
      SERVER_EDITION = var.server_edition
      AUTO_UPDATE = tostring(var.auto_apply_updates)
      NOTIFICATION_EMAIL = var.update_notification_email
      BUCKET_NAME = local.bucket
      SNS_TOPIC_ARN = aws_sns_topic.minecraft_updates[0].arn
    }
  }

  tags = local.cost_tags
}

resource "aws_cloudwatch_event_rule" "version_check" {
  count               = var.enable_auto_updates ? 1 : 0
  name                = "${var.name}-version-check"
  description         = "Check for Minecraft server updates"
  schedule_expression = var.update_check_schedule

  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "version_check" {
  count     = var.enable_auto_updates ? 1 : 0
  rule      = aws_cloudwatch_event_rule.version_check[0].name
  target_id = "CheckMinecraftVersion"
  arn       = aws_lambda_function.version_checker[0].arn
}

resource "aws_lambda_permission" "version_check" {
  count         = var.enable_auto_updates ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.version_checker[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.version_check[0].arn
}

resource "aws_iam_role" "version_checker" {
  count = var.enable_auto_updates ? 1 : 0
  name  = "${var.name}-version-checker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = local.cost_tags
}

resource "aws_iam_role_policy" "version_checker" {
  count = var.enable_auto_updates ? 1 : 0
  name  = "${var.name}-version-checker-policy"
  role  = aws_iam_role.version_checker[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
          "ssm:GetParameter",
          "ssm:PutParameter",
          "ssm:SendCommand",
          "ec2:DescribeInstances"
        ]
        Resource = [
          "arn:aws:ssm:*:*:parameter/minecraft/${module.ec2_minecraft.id[0]}/*",
          "arn:aws:ssm:*:*:document/AWS-RunShellScript",
          "arn:aws:ec2:*:*:instance/${module.ec2_minecraft.id[0]}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [aws_sns_topic.minecraft_updates[0].arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          module.s3.s3_bucket_arn,
          "${module.s3.s3_bucket_arn}/*"
        ]
      }
    ]
  })
}

// Add SSM permissions to EC2 instance role
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

// Add Session Manager policies and remove SSH access
resource "aws_iam_role_policy_attachment" "session_manager" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "session_manager_logging" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
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
  schedule_expression = "cron(0 0 * * ? *)"  # Run daily at midnight UTC

  tags = local.cost_tags
}

resource "aws_cloudwatch_event_target" "activity_prediction" {
  count     = var.enable_monitoring ? 1 : 0
  rule      = aws_cloudwatch_event_rule.activity_prediction[0].name
  target_id = "PredictMinecraftActivity"
  arn       = aws_lambda_function.activity_predictor[0].arn

  input = jsonencode({
    instanceId = module.ec2_minecraft.id[0]
  })
}

resource "aws_lambda_function" "activity_predictor" {
  count         = var.enable_monitoring ? 1 : 0
  filename      = "${path.module}/lambda/activity_predictor.zip"
  function_name = "${var.name}-activity-predictor"
  role         = aws_iam_role.activity_predictor[0].arn
  handler      = "index.handler"
  runtime      = "nodejs18.x"
  timeout      = 300
  memory_size  = 256

  environment {
    variables = {
      INSTANCE_ID = module.ec2_minecraft.id[0]
      RETENTION_DAYS = var.metric_retention_days
      MIN_PLAYER_THRESHOLD = "1"
    }
  }

  tags = local.cost_tags
}

resource "aws_iam_role" "activity_predictor" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-activity-predictor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = local.cost_tags
}

resource "aws_iam_role_policy" "activity_predictor" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-activity-predictor-policy"
  role  = aws_iam_role.activity_predictor[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/minecraft/${module.ec2_minecraft.id[0]}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

// Add backup predictions to S3
resource "aws_s3_object" "default_peak_hours" {
  count  = var.enable_monitoring ? 1 : 0
  bucket = local.bucket
  key    = "config/default_peak_hours.json"
  content = jsonencode({
    peakHours = var.peak_hours,
    lastUpdated = timestamp()
  })
  content_type = "application/json"
}

// DynamoDB table for player statistics
resource "aws_dynamodb_table" "player_stats" {
  count          = var.enable_monitoring ? 1 : 0
  name           = "${var.name}-player-stats"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "playerId"
  range_key      = "timestamp"

  attribute {
    name = "playerId"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.cost_tags, {
    Purpose = "Player Analytics"
  })
}

// Lambda function for player analytics
resource "aws_lambda_function" "player_analytics" {
  count         = var.enable_monitoring ? 1 : 0
  filename      = "${path.module}/lambda/player_analytics.zip"
  function_name = "${var.name}-player-analytics"
  role         = aws_iam_role.player_analytics[0].arn
  handler      = "index.handler"
  runtime      = "nodejs18.x"
  timeout      = 60
  memory_size  = 256

  environment {
    variables = {
      STATS_TABLE = aws_dynamodb_table.player_stats[0].name
    }
  }

  tags = local.cost_tags
}

// IAM role for player analytics Lambda
resource "aws_iam_role" "player_analytics" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-player-analytics-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

// IAM policy for player analytics
resource "aws_iam_role_policy" "player_analytics" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-player-analytics-policy"
  role  = aws_iam_role.player_analytics[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = aws_dynamodb_table.player_stats[0].arn
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
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
      }
    ]
  })
}

// Add player analytics dashboard
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
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer", "AverageSessionDuration", "InstanceId", module.ec2_minecraft.id[0]],
            [".", "PeakConcurrentPlayers", ".", "."]
          ]
          view    = "timeSeries"
          region  = data.aws_region.current.name
          title   = "Player Engagement"
          period  = 3600
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 24
        height = 6
        properties = {
          metrics = [
            ["MinecraftServer", "PlayerRetentionRate", "InstanceId", module.ec2_minecraft.id[0], { 
              label: "Daily Retention",
              period: 86400
            }],
            [".", ".", ".", ".", { 
              label: "Weekly Retention",
              period: 604800
            }]
          ]
          view    = "timeSeries"
          region  = data.aws_region.current.name
          title   = "Player Retention"
          yAxis: {
            left: {
              min: 0,
              max: 100,
              label: "Retention Rate (%)"
            }
          }
        }
      }
    ]
  })
}

// Server health monitoring Lambda
resource "aws_lambda_function" "server_health" {
  count         = var.enable_monitoring ? 1 : 0
  filename      = "${path.module}/lambda/server_health.zip"
  function_name = "${var.name}-server-health"
  role         = aws_iam_role.server_health[0].arn
  handler      = "index.handler"
  runtime      = "nodejs18.x"
  timeout      = 60
  memory_size  = 256

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.minecraft_alerts[0].arn
    }
  }

  tags = merge(local.cost_tags, {
    Component = "HealthMonitoring"
  })
}

resource "aws_iam_role" "server_health" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-server-health"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

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

// Add health monitoring dashboard
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
          view    = "timeSeries"
          region  = data.aws_region.current.name
          title   = "Server Performance"
          period  = 60
          yAxis   = {
            left: {
              min: 0,
              max: 20
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
          view    = "timeSeries"
          region  = data.aws_region.current.name
          title   = "Resource Usage"
          period  = 60
          yAxis   = {
            left: {
              min: 0,
              max: 100
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
          view    = "timeSeries"
          region  = data.aws_region.current.name
          title   = "World Metrics"
          period  = 300
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

// Health monitoring alarms
resource "aws_cloudwatch_metric_alarm" "low_tps" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-low-tps"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "TPS"
  namespace           = "MinecraftServer/Performance"
  period             = "300"
  statistic          = "Average"
  threshold          = "15"
  alarm_description  = "Server TPS has dropped below acceptable levels"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  tags = local.cost_tags
}

resource "aws_cloudwatch_metric_alarm" "high_mspt" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-high-mspt"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "MSPT"
  namespace           = "MinecraftServer/Performance"
  period             = "300"
  statistic          = "Average"
  threshold          = "45"
  alarm_description  = "Server tick processing time is too high"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  tags = local.cost_tags
}

// Schedule for health checks
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

// Add SSM Maintenance Window configuration
resource "aws_ssm_maintenance_window" "minecraft" {
  name                = "${var.name}-maintenance-window"
  schedule            = "cron(0 0 ? * MON *)"  // Every Monday at midnight
  duration            = "2"
  cutoff             = "1"
  schedule_timezone   = "UTC"
  
  tags = local.cost_tags
}

resource "aws_ssm_maintenance_window_target" "minecraft" {
  window_id = aws_ssm_maintenance_window.minecraft.id
  name      = "minecraft-server-maintenance"
  
  targets {
    key    = "InstanceIds"
    values = [module.ec2_minecraft.id[0]]
  }
}

resource "aws_ssm_maintenance_window_task" "minecraft_maintenance" {
  name            = "minecraft-server-maintenance"
  max_concurrency = "1"
  max_errors      = "1"
  priority        = 1
  task_arn        = "AWS-RunShellScript"
  task_type       = "RUN_COMMAND"
  window_id       = aws_ssm_maintenance_window.minecraft.id

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.minecraft.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      parameter {
        name   = "commands"
        values = [
          "#!/bin/bash",
          "echo 'Starting maintenance window tasks'",
          # System updates
          "if command -v apt-get &> /dev/null; then",
          "    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y",
          "elif command -v dnf &> /dev/null; then",
          "    dnf update -y",
          "fi",
          # Backup current state
          "/usr/local/bin/graceful-shutdown.sh",
          "sleep 30",
          # Cleanup old files
          "find ${var.mc_root}/backups -type f -mtime +30 -delete",
          # Optimize world files
          "cd ${var.mc_root}",
          "tar czf world-$(date +%Y%m%d).tar.gz world/",
          "aws s3 cp world-$(date +%Y%m%d).tar.gz s3://${local.bucket}/backups/",
          "rm world-$(date +%Y%m%d).tar.gz",
          # Restart server
          "systemctl start minecraft"
        ]
      }
      service_role_arn = aws_iam_role.maintenance_window.arn
      timeout_seconds = 3600
    }
  }
}

// Add error handling for maintenance window tasks
resource "aws_cloudwatch_metric_alarm" "maintenance_failure" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-maintenance-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "MaintenanceWindowExecutionStatusFailure"
  namespace           = "AWS/SSM"
  period             = "300"
  statistic          = "Sum"
  threshold          = "0"
  alarm_description  = "Maintenance window task execution failed"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    MaintenanceWindowId = aws_ssm_maintenance_window.minecraft.id
  }

  tags = local.cost_tags
}

resource "aws_ssm_maintenance_window_task" "minecraft_maintenance_cleanup" {
  name            = "minecraft-maintenance-cleanup"
  max_concurrency = "1"
  max_errors      = "1"
  priority        = 2
  task_arn        = "AWS-RunShellScript"
  task_type       = "RUN_COMMAND"
  window_id       = aws_ssm_maintenance_window.minecraft.id

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.minecraft.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      parameter {
        name   = "commands"
        values = [
          "#!/bin/bash",
          "# Check if maintenance failed and server is still stopped",
          "if ! systemctl is-active --quiet minecraft; then",
          "    echo 'Server appears to be stopped after maintenance, attempting recovery'",
          "    systemctl start minecraft",
          "    sleep 30",
          "    if ! systemctl is-active --quiet minecraft; then",
          "        aws sns publish --topic-arn ${aws_sns_topic.minecraft_alerts[0].arn} --message 'Server failed to restart after maintenance'",
          "    fi",
          "fi",
          "# Cleanup any temporary maintenance files",
          "find /tmp -name 'minecraft_maintenance_*' -type f -mtime +1 -delete"
        ]
      }
      service_role_arn = aws_iam_role.maintenance_window.arn
      timeout_seconds  = 600
    }
  }
}

// Add IAM role for maintenance window
resource "aws_iam_role" "maintenance_window" {
  name = "${var.name}-maintenance-window-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
      }
    ]
  })

  tags = local.cost_tags
}

resource "aws_iam_role_policy" "maintenance_window" {
  name = "${var.name}-maintenance-window-policy"
  role = aws_iam_role.maintenance_window.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:CancelCommand",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:GetCommandInvocation"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          module.s3.s3_bucket_arn,
          "${module.s3.s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

// Performance monitoring dashboard and alarms
resource "aws_cloudwatch_metric_alarm" "performance_baseline" {
  count               = var.enable_monitoring ? 1 : 0
  alarm_name          = "${var.name}-performance-baseline"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "TPS"
  namespace           = "MinecraftServer/Performance"
  period             = "300"
  statistic          = "Average"
  threshold          = "18"  // Bedrock server should maintain close to 20 TPS
  alarm_description  = "Server performance dropped below baseline"
  alarm_actions      = [aws_sns_topic.minecraft_alerts[0].arn]

  dimensions = {
    InstanceId = module.ec2_minecraft.id[0]
  }
}

resource "aws_cloudwatch_dashboard" "performance" {
  count          = var.enable_monitoring ? 1 : 0
  dashboard_name = "${var.name}-performance"

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
            ["MinecraftServer/Performance", "TPS", "InstanceId", module.ec2_minecraft.id[0]],
            [".", "MSPT", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Server Performance"
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
            ["MinecraftServer", "BackupSize", "Type", "Differential"],
            ["AWS/S3", "BucketSizeBytes", "BucketName", module.s3.s3_bucket_id, "StorageType", "StandardStorage"]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Storage Metrics"
          period  = 3600
        }
      }
    ]
  })
}

