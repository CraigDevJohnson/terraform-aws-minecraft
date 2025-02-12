# Core S3 bucket configuration
resource "random_string" "s3" {
  length  = 12
  special = false
  upper   = false
}

locals {
  using_existing_bucket = signum(length(var.bucket_name)) == 1
  bucket                = length(var.bucket_name) > 0 ? var.bucket_name : "${module.label.id}-${random_string.s3.result}"
}

module "s3" {
  source = "terraform-aws-modules/s3-bucket/aws"

  create_bucket = local.using_existing_bucket ? false : true
  bucket        = local.bucket
  acl           = "private"

  force_destroy = var.bucket_force_destroy
  versioning = {
    enabled    = var.enable_versioning
    mfa_delete = false
  }

  # Public access block
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # Lifecycle rules
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
        days = 365 # Expire old backups after 1 year
      }
    }
  ]

  tags = merge(module.label.tags, local.cost_tags)
}

# Status page bucket (if enabled)
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

# Backup management configurations
resource "aws_s3_bucket_intelligent_tiering_configuration" "backup_tiering" {
  bucket = module.s3.s3_bucket_id
  name   = "BackupTiering"

  tiering {
    access_tier = "DEEP_ARCHIVE_ACCESS"
    days        = 180
  }

  tiering {
    access_tier = "ARCHIVE_ACCESS"
    days        = 90
  }
}

resource "aws_s3_bucket_metric" "backup_metrics" {
  bucket = module.s3.s3_bucket_id
  name   = "BackupMetrics"

  filter {
    prefix = "backups/"
    tags = {
      backup = "true"
    }
  }
}

# Replication configuration
resource "aws_s3_bucket_replication_configuration" "backup_replication" {
  count = var.enable_backup_replication ? 1 : 0

  role   = aws_iam_role.replication[0].arn
  bucket = module.s3.s3_bucket_id

  rule {
    id     = "backup-replication"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = var.backup_replica_bucket_arn
      storage_class = "STANDARD_IA"
    }
  }
}

# Inventory and analysis
resource "aws_s3_bucket_inventory" "backup_inventory" {
  bucket = module.s3.s3_bucket_id
  name   = "BackupInventory"

  included_object_versions = "Current"

  schedule {
    frequency = "Weekly"
  }

  destination {
    bucket {
      bucket_arn = module.s3.s3_bucket_arn
      prefix     = "inventory"
      format     = "CSV"
    }
  }

  optional_fields = ["Size", "LastModifiedDate", "StorageClass", "ETag"]
}

# S3 Analytics configuration
resource "aws_s3_bucket_analytics_configuration" "backup_analytics" {
  bucket = module.s3.s3_bucket_id
  name   = "BackupAnalytics"

  storage_class_analysis {
    data_export {
      destination {
        s3_bucket_destination {
          bucket_arn = module.s3.s3_bucket_arn
          prefix     = "analytics"
        }
      }
    }
  }
}

# EBS volume for game data
resource "aws_ebs_volume" "minecraft" {
  availability_zone = module.ec2_minecraft.availability_zone[0]
  size              = 30
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = merge(local.cost_tags, {
    Name = "${var.name}-minecraft-data"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "minecraft" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.minecraft.id
  instance_id = module.ec2_minecraft.id[0]
}

# Configuration storage
resource "aws_s3_object" "default_peak_hours" {
  count  = var.enable_monitoring ? 1 : 0
  bucket = local.bucket
  key    = "config/default_peak_hours.json"
  content = jsonencode({
    peakHours   = var.peak_hours,
    lastUpdated = timestamp()
  })
  content_type = "application/json"
}

# Automatic snapshot management
resource "aws_dlm_lifecycle_policy" "minecraft" {
  description        = "Minecraft server volume backup policy"
  execution_role_arn = aws_iam_role.dlm_lifecycle_role.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "Daily snapshots"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["23:00"]
      }
      retain_rule {
        count = 7
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

// Add backup predictions to S3
resource "aws_s3_object" "default_peak_hours" {
  count  = var.enable_monitoring ? 1 : 0
  bucket = local.bucket
  key    = "config/default_peak_hours.json"
  content = jsonencode({
    peakHours   = var.peak_hours,
    lastUpdated = timestamp()
  })
  content_type = "application/json"
}

// DynamoDB table for player statistics
resource "aws_dynamodb_table" "player_stats" {
  count        = var.enable_monitoring ? 1 : 0
  name         = "${var.name}-player-stats"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "playerId"
  range_key    = "timestamp"

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