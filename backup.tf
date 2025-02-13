# Backup infrastructure configuration
# Manages backup validation, testing, and monitoring resources

locals {
  backup_validation_error = (
    var.enable_monitoring && (
      var.backup_retention_days == null ||
      var.backup_retention_days < 1 ||
      var.backup_retention_days > 365
    ) ? "backup_retention_days must be between 1 and 365 when monitoring is enabled" : null
  )

  # Backup retention policies
  backup_retention_config = {
    differential = 7   # Keep differential backups for 7 days
    full        = 30   # Keep full backups for 30 days
    archive     = 90   # Move to Glacier after 90 days
  }

  # Additional validation for bucket name
  bucket_name_error = var.enable_monitoring && (
    local.bucket == null || length(local.bucket) < 3
  ) ? "Invalid backup bucket configuration" : null
}

# Validation resources
resource "null_resource" "backup_validation" {
  count = local.backup_validation_error != null ? "Please fix: ${local.backup_validation_error}" : 0
}

resource "null_resource" "bucket_validation" {
  count = local.bucket_name_error != null ? "Please fix: ${local.bucket_name_error}" : 0
}

# AWS Backup vault
resource "aws_backup_vault" "minecraft" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-vault"
  tags  = merge(local.cost_tags, {
    BackupType = "GameServer"
    Component  = "Backup"
  })
}

# AWS Backup plan
resource "aws_backup_plan" "minecraft" {
  count = var.enable_monitoring ? 1 : 0
  name  = "${var.name}-backup-plan"

  rule {
    rule_name         = "weekly-full-backup"
    target_vault_name = aws_backup_vault.minecraft[0].name
    schedule          = "cron(0 0 ? * 1 *)" # Every Sunday at midnight

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }

  tags = local.cost_tags
}

# AWS Backup Selection
resource "aws_backup_selection" "minecraft" {
  count        = var.enable_monitoring ? 1 : 0
  name         = "${var.name}-backup-selection"
  iam_role_arn = aws_iam_role.aws_backup[0].arn
  plan_id      = aws_backup_plan.minecraft[0].id

  resources = [
    module.ec2_minecraft.id[0]
  ]
}

# S3 lifecycle rules for backup management
resource "aws_s3_bucket_lifecycle_configuration" "backup_lifecycle" {
  bucket = local.bucket

  rule {
    id     = "differential-backups"
    status = "Enabled"
    prefix = "backups/differential/"

    expiration {
      days = local.backup_retention_config.differential
    }

    transition {
      days          = 1
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "full-backups"
    status = "Enabled"
    prefix = "backups/full/"

    transition {
      days          = local.backup_retention_config.full
      storage_class = "GLACIER"
    }

    expiration {
      days = local.backup_retention_config.archive
    }
  }

  rule {
    id     = "backup-reports"
    status = "Enabled"
    prefix = "backups/reports/"

    expiration {
      days = 30
    }
  }
}
