// Core terraform configuration for Minecraft server module
locals {
  bucket = "${var.name}-minecraft-${data.aws_caller_identity.current.account_id}"
  tf_tags = {
    Terraform   = "true"
    Environment = var.environment
    Project     = var.name
    ManagedBy   = "terraform"
  }

  # Basic validation
  validate_dns                = var.create_dns_record && (var.zone_id == "" || var.domain_name == "") ? file("ERROR: When create_dns_record is true, both zone_id and domain_name must be provided") : null
  validate_backup_replication = var.enable_backup_replication && var.backup_replica_bucket_arn == "" ? file("ERROR: When enable_backup_replication is true, backup_replica_bucket_arn must be provided") : null
}

// Core module configuration
module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace   = var.namespace
  stage       = var.environment
  name        = var.name
  delimiter   = "-"
  label_order = ["namespace", "stage", "name", "attributes"]
  tags        = merge(var.tags, local.tf_tags)
}

// Core data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
