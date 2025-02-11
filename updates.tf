# Version checker SNS topic
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

# Version checker Lambda
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

# Schedule version checks
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

# IAM role for version checker
resource "aws_iam_role" "version_checker" {
  count = var.enable_auto_updates ? 1 : 0
  name  = "${var.name}-version-checker-role"

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

# IAM policy for version checker
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
