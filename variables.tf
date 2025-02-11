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
  description = "Name to use for servers, tags, etc (e.g. minecraft)"
  type        = string
  default     = "minecraft"
}

variable "namespace" {
  description = "Namespace, which could be your organization name or abbreviation, e.g. 'eg' or 'cp'"
  type        = string
  default     = "games"
}

variable "environment" {
  description = "Environment, e.g. 'prod', 'staging', 'dev', 'pre-prod', 'UAT'"
  type        = string
  default     = "games"
}

variable "tags" {
  description = "Any extra tags to assign to objects"
  type        = map
  default     = {}
}

// Minecraft-specific defaults
variable "mc_port" {
  description = "UDP port for Minecraft Bedrock"
  type        = number
  default     = 19132
}

variable "mc_root" {
  description = "Where to install minecraft on your instance"
  type        = string
  default     = "/home/minecraft"
}

variable "mc_version" {
  description = "Which version of minecraft to install"
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
  default     = 30  // Changed from 15 to reduce S3 operations
}

// You'll want to tune these next two based on the instance type
variable "java_ms_mem" {
  description = "Initial memory for server"
  type        = string
  default     = "1G"  // Optimized for small player count
}

variable "java_mx_mem" {
  description = "Maximum memory for server"
  type        = string
  default     = "1536M"  // Optimized for 3-5 players
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
  default     = "t3a.small"  // Changed from t3a.medium for cost optimization
}

variable "allowed_cidrs" {
  description = "List of allowed CIDR blocks to access the server"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_ip_description" {
  description = "Map of CIDR blocks to their descriptions for documentation"
  type        = map(string)
  default     = {
    "0.0.0.0/0" = "Allow access from anywhere (not recommended for production)"
  }
}

variable "server_edition" {
  description = "Which Minecraft server edition to run (bedrock or java)"
  type        = string
  default     = "bedrock"
  validation {
    condition     = contains(["bedrock", "java"], var.server_edition)
    error_message = "Server edition must be either 'bedrock' or 'java'."
  }
}

variable "enable_auto_shutdown" {
  description = "Enable automatic shutdown during inactive hours"
  type        = bool
  default     = true
}

variable "active_hours_start" {
  description = "Start time for active hours in 24h format (e.g., 8 for 8 AM)"
  type        = number
  default     = 8
  validation {
    condition     = var.active_hours_start >= 0 && var.active_hours_start <= 23
    error_message = "Active hours start must be between 0 and 23."
  }
}

variable "active_hours_end" {
  description = "End time for active hours in 24h format (e.g., 22 for 10 PM)"
  type        = number
  default     = 22
  validation {
    condition     = var.active_hours_end >= 0 && var.active_hours_end <= 23
    error_message = "Active hours end must be between 0 and 23."
  }
}

variable "min_players_to_start" {
  description = "Minimum number of connection attempts to start server outside active hours"
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
  description = "Enable server status webpage hosted in S3"
  type        = bool
  default     = false
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
      limit   = number  // Requests per 5 minutes
    })
    protocol_enforcement = object({
      enabled = bool
      strict_mode = bool  // Enforce strict Minecraft protocol rules
    })
    ip_reputation = object({
      enabled = bool
      block_anonymous_ip = bool
    })
  })
  default = {
    rate_limit = {
      enabled = true
      limit   = 2000
    }
    protocol_enforcement = {
      enabled = true
      strict_mode = false
    }
    ip_reputation = {
      enabled = true
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
  default     = "cron(0 0 * * ? *)"  // Daily at midnight UTC
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
  description = "Enable enhanced monitoring and alerting"
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address for server alerts and notifications"
  type        = string
  default     = ""
}

variable "metric_retention_days" {
  description = "Number of days to retain detailed metrics"
  type        = number
  default     = 90
}

variable "monitoring_interval" {
  description = "Interval in seconds for collecting metrics"
  type        = number
  default     = 60
}

variable "alert_thresholds" {
  description = "Thresholds for various monitoring alerts"
  type = object({
    cpu_high = number
    memory_high = number
    disk_io_high = number
    player_inactivity_minutes = number
  })
  default = {
    cpu_high = 80
    memory_high = 85
    disk_io_high = 1000
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
  default     = "cron(0 0 ? * MON *)"  // Monday at midnight
}

variable "maintenance_window_duration" {
  description = "Duration in hours for maintenance window"
  type        = number
  default     = 2
}

