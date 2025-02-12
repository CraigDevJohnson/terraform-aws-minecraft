// EC2 instance role
resource "aws_iam_role" "allow_s3" {
  name = "${var.name}-allow-ec2-to-s3"

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

  tags = local.cost_tags
}

resource "aws_iam_instance_profile" "mc" {
  name = "${var.name}-instance-profile"
  role = aws_iam_role.allow_s3.name
}

resource "aws_iam_role_policy" "mc_allow_ec2_to_s3" {
  name = "${var.name}-allow-ec2-to-s3"
  role = aws_iam_role.allow_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [module.s3.s3_bucket_arn]
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" : data.aws_caller_identity.aws.account_id
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = ["${module.s3.s3_bucket_arn}/*"]
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" : data.aws_caller_identity.aws.account_id
          }
        }
      }
    ]
  })
}

// Lambda roles
resource "aws_iam_role" "lambda_role" {
  name = "${var.name}-lambda-manager"

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

  tags = local.cost_tags
}

resource "aws_iam_role_policy" "lambda_ec2_policy" {
  name = "${var.name}-lambda-ec2-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:DescribeInstances"
        ]
        Resource = "arn:aws:ec2:*:${data.aws_caller_identity.aws.account_id}:instance/${module.ec2_minecraft.id[0]}"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.aws.account_id}:log-group:/aws/lambda/${var.name}-*:*"
      }
    ]
  })
}

// DLM role for EBS snapshots
resource "aws_iam_role" "dlm_lifecycle_role" {
  name = "${var.name}-dlm-lifecycle-role"

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

  tags = local.cost_tags
}

resource "aws_iam_role_policy" "dlm_lifecycle" {
  name = "${var.name}-dlm-lifecycle-policy"
  role = aws_iam_role.dlm_lifecycle_role.id

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
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:*::snapshot/*"
      }
    ]
  })
}

// SSM role attachments
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "session_manager" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

// Additional IAM role for Session Manager
resource "aws_iam_role_policy_attachment" "session_manager_logging" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

// Add WAF monitoring role
resource "aws_iam_role" "waf_monitoring" {
  name = "${var.name}-waf-monitor"

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

  tags = local.cost_tags
}

// Add monitoring role permissions
resource "aws_iam_role_policy" "monitoring_permissions" {
  name = "${var.name}-monitoring-permissions"
  role = aws_iam_role.lambda_monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

// CloudWatch agent role
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
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

// CloudWatch Agent IAM role policy
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.allow_s3.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

// IAM role for S3 access
resource "aws_iam_role" "allow_s3" {
  name = "${module.label.id}-allow-ec2-to-s3"
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
  name = "${module.label.id}-allow-ec2-to-s3"
  role = aws_iam_role.allow_s3.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ],
        Resource = [module.s3.s3_bucket_arn],
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" : data.aws_caller_identity.aws.account_id
          }
        }
      },
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource = ["${module.s3.s3_bucket_arn}/*"],
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" : data.aws_caller_identity.aws.account_id
          }
        }
      }
    ]
  })
}