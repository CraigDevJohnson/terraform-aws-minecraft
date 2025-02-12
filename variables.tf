variable "vpc_id" {
  description = "VPC for security group"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "VPC subnet id to place the instance"
  type        = string
  default     = ""
}

variable "region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-west-2"
}

variable "key_name" {
  description = "EC2 key name for provisioning and access"
  type        = string
  default     = ""
}

variable "bucket_name" {
  description = "Bucket name for persisting minecraft world"
  type        = string
  default     = ""
}

variable "bucket_force_destroy" {
  description = "A boolean that indicates all objects should be deleted from the bucket so that the bucket can be destroyed without error. This will destroy your minecraft world!"
  type        = bool
  default     = false
}

variable "bucket_object_versioning" {
  description = "Enable object versioning (default = true). Note this may incur more cost."
  type        = bool
  default     = true
}

// For tags
variable "name" {
  description = "Name prefix for resources"
  type        = string
}

variable "namespace" {
  description = "Namespace for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment (prod, dev, etc.)"
  type        = string
}

variable "tags" {
  description = "Any extra tags to assign to objects"
  type        = map(any)
  default     = {}
}

// Minecraft-specific defaults
variable "mc_port" {
  description = "Minecraft server port"
  type        = number
  default     = 19132
}

variable "mc_root" {
  description = "Minecraft server root directory"
  type        = string
  default     = "/opt/minecraft"
}

variable "mc_version" {
  description = "Minecraft server version"
  type        = string
  default     = "latest"
}

variable "mc_type" {
  description = "Type of minecraft distribution - snapshot or release"
  type        = string
  default     = "release"
}

variable "mc_backup_freq" {
  description = "How often (mins) to sync to S3"
  type        = number
  default     = 30 // Changed from 15 to reduce S3 operations
}

variable "enable_versioning" {
  description = "Enable S3 bucket versioning"
  type        = bool
  default     = true
}

variable "enable_backup_replication" {
  description = "Enable backup replication"
  type        = bool
  default     = false
}

variable "backup_replica_bucket_arn" {
  type        = string
  description = "ARN of the backup replica bucket for replication"
}

// You'll want to tune these next two based on the instance type
variable "java_ms_mem" {
  description = "Initial memory for server"
  type        = string
  default     = "1G" // Optimized for small player count
}

variable "java_mx_mem" {
  description = "Maximum memory for server"
  type        = string
  default     = "1536M" // Optimized for 3-5 players
}

// Instance vars
variable "associate_public_ip_address" {
  description = "By default, our server has a public IP"
  type        = bool
  default     = true
}

variable "ami" {
  description = "AMI to use for the instance - will default to latest Ubuntu"
  type        = string
  default     = ""
}

// https://aws.amazon.com/ec2/instance-types/
variable "instance_type" {
  description = "EC2 instance type/size - optimized for 3-5 player Bedrock server"
  type        = string
  default     = "t3a.small" // Changed from t3a.medium for cost optimization
}

variable "allowed_cidrs" {
  description = "List of CIDRs allowed to connect"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_ip_description" {
  description = "Map of CIDR blocks to their descriptions for documentation"
  type        = map(string)
  default = {
    "0.0.0.0/0" = "Allow access from anywhere (not recommended for production)"
  }
}

variable "server_edition" {
  description = "Minecraft server edition (java or bedrock)"
  type        = string
  default     = "bedrock"
  validation {
    condition     = contains(["java", "bedrock"], var.server_edition)
    error_message = "Server edition must be either 'java' or 'bedrock'."
  }
}

variable "enable_auto_shutdown" {
  description = "Enable automatic shutdown when inactive"
  type        = bool
  default     = true
}

variable "active_hours_start" {
  description = "Start of active hours (24h format)"
  type        = string
  default     = "09:00"
}

variable "active_hours_end" {
  description = "End of active hours (24h format)"
  type        = string
  default     = "23:00"
}

variable "min_players_to_start" {
  description = "Minimum players to start server"
  type        = number
  default     = 1
}

variable "create_vpc_endpoints" {
  description = "Whether to create VPC endpoints for SSM and S3"
  type        = bool
  default     = false
}

variable "enable_notifications" {
  description = "Enable SNS notifications for server events"
  type        = bool
  default     = false
}

variable "notification_email" {
  description = "Email address for server notifications"
  type        = string
  default     = ""
}

variable "enable_status_page" {
  description = "Enable public status page"
  type        = bool
  default     = true
}

variable "metrics_retention_days" {
  description = "Number of days to retain CloudWatch metrics"
  type        = number
  default     = 30
}

variable "domain_name" {
  description = "Domain name for the Minecraft server (e.g., minecraft.example.com)"
  type        = string
  default     = ""
}

variable "create_dns_record" {
  description = "Whether to create DNS record in Route 53"
  type        = bool
  default     = false
}

variable "zone_id" {
  description = "Route 53 Hosted Zone ID where DNS record will be added"
  type        = string
  default     = ""
}

variable "dns_ttl" {
  description = "TTL for DNS record"
  type        = number
  default     = 300
}

variable "budget_limit" {
  description = "Monthly budget limit in USD"
  type        = number
  default     = 50
}

variable "budget_alert_emails" {
  description = "Email addresses to notify for budget alerts"
  type        = list(string)
  default     = []
}

variable "budget_alert_threshold" {
  description = "Alert when budget reaches this percentage (0-100)"
  type        = number
  default     = 80
  validation {
    condition     = var.budget_alert_threshold > 0 && var.budget_alert_threshold <= 100
    error_message = "Budget alert threshold must be between 1 and 100."
  }
}

variable "enable_cost_alerts" {
  description = "Enable AWS Budget alerts"
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Enable WAF protection for the server"
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "Maximum requests per 5-minute period per IP"
  type        = number
  default     = 2000
}

variable "waf_block_count_threshold" {
  description = "Number of requests to trigger IP block"
  type        = number
  default     = 100
}

variable "waf_rules" {
  description = "WAF rule sets to enable"
  type = object({
    rate_limit = object({
      enabled = bool
      limit   = number // Requests per 5 minutes
    })
    protocol_enforcement = object({
      enabled     = bool
      strict_mode = bool // Enforce strict Minecraft protocol rules
    })
    ip_reputation = object({
      enabled            = bool
      block_anonymous_ip = bool
    })
  })
  default = {
    rate_limit = {
      enabled = true
      limit   = 2000
    }
    protocol_enforcement = {
      enabled     = true
      strict_mode = false
    }
    ip_reputation = {
      enabled            = true
      block_anonymous_ip = true
    }
  }
}

variable "waf_ip_retention_days" {
  description = "Number of days to retain blocked IPs"
  type        = number
  default     = 7
}

variable "enable_auto_updates" {
  description = "Enable automatic server version updates"
  type        = bool
  default     = true
}

variable "update_check_schedule" {
  description = "How often to check for updates (cron expression)"
  type        = string
  default     = "cron(0 0 * * ? *)" // Daily at midnight UTC
}

variable "update_notification_email" {
  description = "Email to notify when updates are available/applied"
  type        = string
  default     = ""
}

variable "auto_apply_updates" {
  description = "Automatically apply updates when available"
  type        = bool
  default     = false
}

variable "enable_monitoring" {
  description = "Enable enhanced monitoring"
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address for alerts"
  type        = string
}

variable "metric_retention_days" {
  description = "Days to retain CloudWatch metrics"
  type        = number
  default     = 30
}

variable "monitoring_interval" {
  description = "Interval in seconds for collecting metrics"
  type        = number
  default     = 60
}

variable "alert_thresholds" {
  description = "Thresholds for various monitoring alerts"
  type = object({
    cpu_high                  = number
    memory_high               = number
    disk_io_high              = number
    player_inactivity_minutes = number
  })
  default = {
    cpu_high                  = 80
    memory_high               = 85
    disk_io_high              = 1000
    player_inactivity_minutes = 30
  }
}

variable "peak_hours" {
  description = "List of peak hours (0-23) to prevent auto-shutdown"
  type        = list(number)
  default     = []
  validation {
    condition     = length([for h in var.peak_hours : h if h >= 0 && h < 24]) == length(var.peak_hours)
    error_message = "Peak hours must be between 0 and 23."
  }
}

variable "maintenance_window_schedule" {
  description = "Cron expression for maintenance window"
  type        = string
  default     = "cron(0 0 ? * MON *)" // Monday at midnight
}

variable "maintenance_window_duration" {
  description = "Duration in hours for maintenance window"
  type        = number
  default     = 2
}

variable "os_type" {
  description = "The operating system to use for the Minecraft server. Valid values are: amazon-linux-2, amazon-linux-2023, ubuntu"
  type        = string
  default     = "amazon-linux-2023"

  validation {
    condition     = contains(["amazon-linux-2", "amazon-linux-2023", "ubuntu"], var.os_type)
    error_message = "Valid values for os_type are: amazon-linux-2, amazon-linux-2023, ubuntu"
  }
}

locals {
  vpc_id    = length(var.vpc_id) > 0 ? var.vpc_id : data.aws_vpc.default.id
  subnet_id = length(var.subnet_id) > 0 ? var.subnet_id : sort(data.aws_subnet_ids.default.ids)[0]

  bucket = length(var.bucket_name) > 0 ? var.bucket_name : "${module.label.id}-${random_string.s3.result}"

  cost_tags = {
    Project     = var.name
    Environment = var.environment
    CostCenter  = "Gaming"
    ServerType  = var.server_edition
    Managed     = "Terraform"
  }

  tf_tags = {
    Terraform   = "true"
    Environment = var.environment
    Project     = var.name
  }
}

variable "maintenance_schedule" {
  description = "Cron expression for maintenance window schedule"
  type        = string
  default     = "cron(0 0 * * ? *)" # Default: Run at midnight daily
}