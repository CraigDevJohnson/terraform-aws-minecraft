# IAM Resources for Minecraft Server Infrastructure
# --------------------------------------------

locals {
  iam_tags = merge(local.cost_tags, {
    Service = "IAM"
  })

  # Common policy statements
  cloudwatch_logging_statement = {
    Effect = "Allow"
    Action = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.aws.account_id}:log-group:/aws/*:*"
  }

  s3_access_statement = {
    Effect = "Allow"
    Action = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:DeleteObject"
    ]
    Resource = [
      module.s3.s3_bucket_arn,
      "${module.s3.s3_bucket_arn}/*"
    ]
  }

  sns_publish_statement = {
    Effect = "Allow"
    Action = ["sns:Publish"]
    Resource = [
      aws_sns_topic.minecraft_alerts[0].arn,
      aws_sns_topic.minecraft_updates[0].arn
    ]
  }
}

#
# EC2 Instance Role
#

resource "aws_iam_role" "minecraft_server" {
  name = "${var.name}-server-role"
  description = "Role for Minecraft server EC2 instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.iam_tags
}

resource "aws_iam_instance_profile" "minecraft_server" {
  name = "${var.name}-server-profile"
  role = aws_iam_role.minecraft_server.name
  tags = local.iam_tags
}

resource "aws_iam_role_policy" "minecraft_server" {
  name = "${var.name}-server-policy"
  role = aws_iam_role.minecraft_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.s3_access_statement,
      local.cloudwatch_logging_statement,
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.aws.account_id}:parameter/minecraft/*"
      }
    ]
  })
}

# Attach AWS managed policies for EC2 instance
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.minecraft_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.minecraft_server.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

#
# Maintenance Window Role
#

resource "aws_iam_role" "maintenance_window" {
  name        = "${var.name}-maintenance-window"
  description = "Role for Minecraft server maintenance window tasks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ssm.amazonaws.com"
      }
    }]
  })

  tags = local.iam_tags
}

resource "aws_iam_role_policy" "maintenance_window" {
  name = "${var.name}-maintenance-window"
  role = aws_iam_role.maintenance_window.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.s3_access_statement,
      local.cloudwatch_logging_statement,
      local.sns_publish_statement,
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation"
        ]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.aws.account_id}:document/AWS-RunShellScript",
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.aws.account_id}:instance/${module.ec2_minecraft.id[0]}"
        ]
      }
    ]
  })
}

#
# Data Lifecycle Manager Role
#

resource "aws_iam_role" "dlm_lifecycle" {
  name        = "${var.name}-dlm-lifecycle"
  description = "Role for EBS snapshot lifecycle management"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "dlm.amazonaws.com"
      }
    }]
  })

  tags = local.iam_tags
}

resource "aws_iam_role_policy" "dlm_lifecycle" {
  name = "${var.name}-dlm-lifecycle"
  role = aws_iam_role.dlm_lifecycle.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot",
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*::snapshot/*"
      }
    ]
  })
}

# WAF monitoring role is now consolidated in lambda.tf