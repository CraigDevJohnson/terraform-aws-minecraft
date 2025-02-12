# Status page S3 bucket
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
      }
    ]
  })
}

# Status page updater Lambda
resource "aws_lambda_function" "status_updater" {
  count         = var.enable_status_page ? 1 : 0
  filename      = "${path.module}/lambda/status_updater.zip"
  function_name = "${var.name}-status-updater"
  role          = aws_iam_role.status_updater[0].arn
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

# Status updater IAM role
resource "aws_iam_role" "status_updater" {
  count = var.enable_status_page ? 1 : 0
  name  = "${var.name}-status-updater"

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

# Status updater policy
resource "aws_iam_role_policy" "status_updater" {
  count = var.enable_status_page ? 1 : 0
  name  = "${var.name}-status-updater-policy"
  role  = aws_iam_role.status_updater[0].id

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

# Status update scheduler
resource "aws_cloudwatch_event_rule" "status_update" {
  count               = var.enable_status_page ? 1 : 0
  name                = "${var.name}-status-update"
  description         = "Trigger status page updates"
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
