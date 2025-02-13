# Lambda Function Configuration
# --------------------------------------------

locals {
  lambda_tags = merge(local.cost_tags, {
    Service = "Lambda"
  })

  lambda_monitoring_policy = jsonencode({
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
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter",
          "ssm:SendCommand"
        ]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.aws.account_id}:parameter/minecraft/*",
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.aws.account_id}:document/AWS-RunShellScript"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StartInstances",
          "ec2:StopInstances"
        ]
        Resource = "arn:aws:ec2:*:${data.aws_caller_identity.aws.account_id}:instance/${module.ec2_minecraft.id[0]}"
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = [
          aws_sns_topic.minecraft_alerts[0].arn,
          aws_sns_topic.minecraft_updates[0].arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "wafv2:GetIPSet",
          "wafv2:UpdateIPSet",
          "wafv2:GetWebACL",
          "wafv2:UpdateWebACL",
          "wafv2:GetSampledRequests"
        ]
        Resource = [
          aws_wafv2_ip_set.minecraft[0].arn,
          aws_wafv2_web_acl.minecraft[0].arn
        ]
      }
    ]
  })
}

# Base Lambda monitoring role
resource "aws_iam_role" "lambda_monitoring" {
  name        = "${var.name}-lambda-monitoring"
  description = "Base role for Minecraft server monitoring Lambda functions"

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

  tags = local.lambda_tags
}

# Attach base monitoring policy
resource "aws_iam_role_policy" "lambda_monitoring" {
  name   = "${var.name}-lambda-monitoring"
  role   = aws_iam_role.lambda_monitoring.id
  policy = local.lambda_monitoring_policy
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

# Lambda Functions and Related Resources
# --------------------------------------------

locals {
  common_lambda_config = {
    runtime     = "nodejs18.x"
    memory_size = 256
    timeout     = 60
  }
}

#
# Activity Prediction Lambda
#

resource "aws_lambda_function" "activity_predictor" {
  filename         = "${path.module}/lambda/activity_predictor.zip"
  function_name    = "${var.name}-activity-predictor"
  role            = aws_iam_role.lambda_monitoring.arn
  handler         = "index.handler"
  runtime         = local.common_lambda_config.runtime
  memory_size     = local.common_lambda_config.memory_size
  timeout         = 300 # Longer timeout for ML processing

  environment {
    variables = {
      INSTANCE_ID          = module.ec2_minecraft.id[0]
      RETENTION_DAYS       = var.metric_retention_days
      MIN_PLAYER_THRESHOLD = "1"
    }
  }

  tags = local.lambda_tags

  depends_on = [aws_cloudwatch_log_group.activity_predictor]
}

resource "aws_cloudwatch_log_group" "activity_predictor" {
  name              = "/aws/lambda/${var.name}-activity-predictor"
  retention_in_days = 14
  tags             = local.lambda_tags
}

#
# Server Status Update Lambda
#

resource "aws_lambda_function" "status_updater" {
  count = var.enable_status_page ? 1 : 0

  filename      = "${path.module}/lambda/status_updater.zip"
  function_name = "${var.name}-status-updater"
  role         = aws_iam_role.lambda_monitoring.arn
  handler      = "index.handler"
  runtime      = local.common_lambda_config.runtime
  timeout      = local.common_lambda_config.timeout

  environment {
    variables = {
      STATUS_BUCKET = aws_s3_bucket.status_page[0].id
      SERVER_IP     = module.ec2_minecraft.public_ip[0]
      SERVER_PORT   = var.mc_port
      SERVER_TYPE   = var.server_edition
      DOMAIN_NAME   = var.domain_name
    }
  }

  tags = local.lambda_tags

  depends_on = [aws_cloudwatch_log_group.status_updater]
}

resource "aws_cloudwatch_log_group" "status_updater" {
  count = var.enable_status_page ? 1 : 0

  name              = "/aws/lambda/${var.name}-status-updater"
  retention_in_days = 14
  tags             = local.lambda_tags
}

#
# Version Checker Lambda
#

resource "aws_lambda_function" "version_checker" {
  count = var.enable_auto_updates ? 1 : 0

  filename      = "${path.module}/lambda/version_checker.zip"
  function_name = "${var.name}-version-checker"
  role         = aws_iam_role.lambda_monitoring.arn
  handler      = "index.handler"
  runtime      = local.common_lambda_config.runtime
  timeout      = local.common_lambda_config.timeout

  environment {
    variables = {
      INSTANCE_ID    = module.ec2_minecraft.id[0]
      SERVER_EDITION = var.server_edition
      AUTO_UPDATE    = tostring(var.auto_apply_updates)
      SNS_TOPIC_ARN  = aws_sns_topic.minecraft_updates[0].arn
    }
  }

  tags = local.lambda_tags

  depends_on = [aws_cloudwatch_log_group.version_checker]

  lifecycle {
    precondition {
      condition     = var.server_edition == "java" || var.server_edition == "bedrock"
      error_message = "server_edition must be either 'java' or 'bedrock'"
    }
  }
}

resource "aws_cloudwatch_log_group" "version_checker" {
  count = var.enable_auto_updates ? 1 : 0

  name              = "/aws/lambda/${var.name}-version-checker"
  retention_in_days = 14
  tags             = local.lambda_tags
}

#
# CloudWatch Event Rules & Targets
#

resource "aws_cloudwatch_event_rule" "version_check" {
  count = var.enable_auto_updates ? 1 : 0

  name                = "${var.name}-version-check"
  description         = "Trigger version check for Minecraft server"
  schedule_expression = "rate(6 hours)"
  tags               = local.lambda_tags
}

resource "aws_cloudwatch_event_target" "version_check" {
  count = var.enable_auto_updates ? 1 : 0

  rule      = aws_cloudwatch_event_rule.version_check[0].name
  target_id = "CheckMinecraftVersion"
  arn       = aws_lambda_function.version_checker[0].arn
}

resource "aws_lambda_permission" "version_check" {
  count = var.enable_auto_updates ? 1 : 0

  statement_id  = "AllowVersionCheckEvent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.version_checker[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.version_check[0].arn
}

resource "aws_cloudwatch_event_rule" "activity_prediction" {
  name                = "${var.name}-activity-prediction"
  description         = "Trigger activity prediction analysis"
  schedule_expression = "rate(15 minutes)"
  tags               = local.lambda_tags
}

resource "aws_cloudwatch_event_target" "activity_prediction" {
  rule      = aws_cloudwatch_event_rule.activity_prediction.name
  target_id = "PredictMinecraftActivity"
  arn       = aws_lambda_function.activity_predictor.arn
}

resource "aws_lambda_permission" "activity_prediction" {
  statement_id  = "AllowActivityPredictionEvent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.activity_predictor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.activity_prediction.arn
}
