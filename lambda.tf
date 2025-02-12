# Common Lambda IAM role for monitoring functions
resource "aws_iam_role" "lambda_monitoring" {
  name = "${var.name}-lambda-monitoring"

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

# Lambda core role
resource "aws_iam_role" "lambda_role" {
  name = "${module.label.id}-lambda-manager"

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
}

# Lambda core policy
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
          "ec2:DescribeInstances"
        ],
        Resource = "arn:aws:ec2:*:${data.aws_caller_identity.aws.account_id}:instance/${module.ec2_minecraft.id[0]}"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.aws.account_id}:log-group:/aws/lambda/${var.name}-*:*"
      },
      {
        Effect = "Allow",
        Action = [
          "cloudwatch:PutMetricData"
        ],
        Resource = "*",
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" : "MinecraftServer"
          }
        }
      }
    ]
  })
}

# Activity predictor Lambda
resource "aws_lambda_function" "activity_predictor" {
  filename      = "${path.module}/lambda/activity_predictor.zip"
  function_name = "${var.name}-activity-predictor"
  role          = aws_iam_role.lambda_monitoring.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 300
  memory_size   = 256

  environment {
    variables = {
      INSTANCE_ID          = module.ec2_minecraft.id[0]
      RETENTION_DAYS       = var.metric_retention_days
      MIN_PLAYER_THRESHOLD = "1"
    }
  }

  tags = local.cost_tags
}

# Status page updater function
resource "aws_lambda_function" "status_updater" {
  count         = var.enable_status_page ? 1 : 0
  filename      = "${path.module}/lambda/status_updater.zip"
  function_name = "${var.name}-status-updater"
  role          = aws_iam_role.lambda_status_updater[0].arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 30

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

# Status updater role
resource "aws_iam_role" "lambda_status_updater" {
  count = var.enable_status_page ? 1 : 0
  name  = "${var.name}-status-updater-role"

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
}

# Version checker Lambda
resource "aws_lambda_function" "version_checker" {
  count         = var.enable_auto_updates ? 1 : 0
  filename      = "${path.module}/lambda/version_checker.zip"
  function_name = "${var.name}-version-checker"
  role          = aws_iam_role.lambda_monitoring.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  timeout       = 60

  environment {
    variables = {
      INSTANCE_ID    = module.ec2_minecraft.id[0]
      SERVER_EDITION = var.server_edition
      AUTO_UPDATE    = tostring(var.auto_apply_updates)
      SNS_TOPIC_ARN  = aws_sns_topic.minecraft_updates[0].arn
    }
  }

  tags = local.cost_tags
}
