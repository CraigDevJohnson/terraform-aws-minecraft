# Network Outputs
output "vpc_id" {
  description = "ID of the VPC where the Minecraft server is deployed"
  value       = local.vpc_id
}

output "subnet_id" {
  description = "ID of the subnet where the Minecraft server is deployed"
  value       = local.subnet_id
}

# Instance Outputs
output "instance_id" {
  description = "EC2 instance ID of the Minecraft server"
  value       = module.ec2_minecraft.id[0]
}

output "instance_public_ip" {
  description = "Public IP address of the Minecraft server"
  value       = module.ec2_minecraft.public_ip[0]
}

output "instance_profile" {
  description = "Name of the IAM instance profile attached to the server"
  value       = aws_iam_instance_profile.mc.name
}

# Server Access Outputs
output "minecraft_server_address" {
  description = "Complete Minecraft server address with port for client connection"
  value       = "${module.ec2_minecraft.public_ip[0]}:${var.mc_port}"
}

# SSH Key Outputs
output "ssh_public_key_openssh" {
  description = "OpenSSH formatted public key"
  value       = tls_private_key.ec2_ssh.*.public_key_openssh
  sensitive   = false
}

output "ssh_public_key_pem" {
  description = "PEM formatted public key"
  value       = tls_private_key.ec2_ssh.*.public_key_pem
  sensitive   = false
}

output "ssh_private_key_pem" {
  description = "PEM formatted private key (sensitive)"
  value       = tls_private_key.ec2_ssh.*.private_key_pem
  sensitive   = true
}

# Storage Outputs
output "backup_bucket_name" {
  description = "Name of the S3 bucket used for server backups"
  value       = local.bucket
}

# Monitoring Outputs
output "cloudwatch_dashboard_url" {
  description = "URL to the CloudWatch dashboard for server monitoring"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${var.name}-monitoring"
}

# Helper Outputs
output "ssh_connection_string" {
  description = "SSH connection string for the Minecraft server (empty if using existing key)"
  value       = length(var.key_name) > 0 ? "" : <<EOT

Ubuntu:        ssh -i ${path.module}/ec2-private-key.pem ubuntu@${module.ec2_minecraft.public_ip[0]}
Amazon Linux:  ssh -i ${path.module}/ec2-private-key.pem ec2-user@${module.ec2_minecraft.public_ip[0]}

EOT
}

# Status Page Outputs
# ------------------

output "status_page_url" {
  description = "URL of the status page"
  value       = var.enable_status_page ? "http://${aws_s3_bucket.status_page[0].website_endpoint}" : null
}

output "status_page_bucket" {
  description = "Name of the S3 bucket hosting the status page"
  value       = var.enable_status_page ? aws_s3_bucket.status_page[0].id : null
}

output "status_page_waf_id" {
  description = "ID of the WAF ACL protecting the status page"
  value       = var.enable_status_page ? aws_wafv2_web_acl.status_page[0].id : null
}

output "status_page_dlq_url" {
  description = "URL of the Dead Letter Queue for failed status updates"
  value       = var.enable_status_page ? aws_sqs_queue.status_dlq[0].url : null
}

output "status_page_function_name" {
  description = "Name of the Lambda function updating the status page"
  value       = var.enable_status_page ? aws_lambda_function.status_updater[0].function_name : null
}

output "status_page_dashboard_url" {
  description = "URL of the CloudWatch dashboard for status page monitoring"
  value       = var.enable_status_page ? "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${var.name}-status-page" : null
}

# Local File Management
resource "local_file" "private_key" {
  count = length(var.key_name) > 0 ? 0 : 1

  content              = tls_private_key.ec2_ssh[0].private_key_pem
  filename             = "${path.module}/ec2-private-key.pem"
  directory_permission = "0700"
  file_permission     = "0600"  # More restrictive file permissions for private key
}
