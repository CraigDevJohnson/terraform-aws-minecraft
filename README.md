# terraform-aws-minecraft

Terraform module to provision an AWS EC2 instance with an S3 backing store for running the [Minecraft](https://minecraft.net/en-us/) server.

## Features
* Download and play any available version of minecraft (downloaded from Mojang)
* Configurable syncing (frequency in minutes) of game folder on EC2 to S3
* When done, keep your game in S3 and pick up where you left off

## Prerequisites

- AWS CLI installed and configured
- Terraform >= 1.0
- Node.js >= 18 (for Lambda functions)
- zip (for packaging Lambda functions)
- (Optional) infracost for cost estimation

## Quick Start

1. Configure AWS credentials:
```bash
aws configure
```

2. Update terraform.tfvars with your configuration:
```hcl
namespace         = "minecraft"
environment       = "prod"
name             = "mc-bedrock"
region           = "us-west-2"
alert_email      = "your.email@example.com"
allowed_cidrs    = ["your.ip.address/32"]
```

3. Run the deployment script:
```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

4. Review the plan and cost estimate

5. Apply the configuration:
```bash
terraform apply tfplan
```

## Post-Deployment

1. Configure DNS (if using custom domain)
2. Verify monitoring dashboards
3. Test backup system
4. Validate auto-shutdown functionality

## Management

- Start server: AWS Systems Manager or CloudWatch dashboard
- Monitor: CloudWatch dashboards
- Backups: Check S3 bucket and CloudWatch metrics
- Updates: Automatic via Lambda function

## Security

- No direct SSH access (use Session Manager)
- WAF protection enabled
- Auto-updated server version
- Encrypted backups and storage

## Cost Management

- Auto-shutdown when inactive
- Optimized storage lifecycle
- Performance-based scaling
- Regular cost monitoring

## Troubleshooting

See CloudWatch logs for:
- /aws/lambda/minecraft-*
- /minecraft/server
- VPC Flow Logs

## Support

Create an issue in the repository for:
- Bug reports
- Feature requests
- Configuration help

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add pre-commit hooks:
```bash
pre-commit install
```
4. Make changes
5. Submit a pull request

## Usage
Example from latest version, using default values for everything:

```
module "minecraft" {
  source = "git@github.com:darrelldavis/terraform-aws-minecraft.git?ref=master"
}
```
This will create all needed resources, including an S3 bucket to persist the game state. If you subsequently use `terraform destroy` the S3 bucket will not be destroyed as it will not be empty. You can choose to delete the bucket yourself with `aws s3 rb s3://bucket-name --force` or keep the game for future play. If the latter, add the bucket as `bucket_name` in your module call, for example:

```
module "minecraft" {
  source = "git@github.com:darrelldavis/terraform-aws-minecraft.git?ref=master"
  bucket_name = "games-minecraft-1234567890"
}
```
This will sync the bucket contents to the EC2 instance before starting minecraft and you can pick up play where you left off!

See [examples](./examples) directory for full example(s).

Example using original (legacy) version:

```
module "minecraft" {
  source = "git@github.com:darrelldavis/terraform-aws-minecraft.git?ref=v1.0"
}
```

## Inputs

|Name|Description|Default|Required|
|:--|:--|:--:|:--:|
|allowed_cidrs|Allow these CIDR blocks to the server - default is the Universe|0.0.0.0/0||
|ami|AMI to use for the instance, tested with Ubuntu and Amazon Linux 2 LTS|latest Ubuntu||
|associate\_public\_ip\_address|Toggle public IP|true||
|bucket_name|Bucket name for persisting minecraft world|generated name||
|environment|Environment (for tags)|prod||
|instance_type|EC2 instance type/size|t2.medium (NOTE: **NOT** free tier!)||
|java\_ms\_mem|Java initial and minimum heap size|2G||
|java\_mx\_mem|Java maximum heap size|2G||
|key_name|EC2 key name for provisioning and access|generated||
|name|Name to use for servers, tags, etc (e.g. minecraft)|mc||
|namespace|Namespace, which could be your organization name or abbreviation (for tags)|games||
|mc\_backup\_freq|How often (mins) to sync to S3|5||
|mc_port|TCP port for minecraft. If you change this from the default, you also need to manually edit the minecraft `server.properties` file in S3 and/or EC2 instannce after the build. (todo: install custom `server.properties`)|25565||
|mc_root|Where to install minecraft|`/home/minecraft`||
|mc_version|Which version of minecraft to install|latest||
|subnet_id|VPC subnet id to place the instance|chosen from default VPC||
|tags|Any extra tags to assign to objects|{}||
|vpc_id|VPC for security group|default VPC||

## Outputs

|Name|Description|
|:--|:--|
|ec2\_instance\_profile|EC2 instance profile|
|id|EC2 instance ID|
|private_key|The private key data in PEM format|
|public_ip|Instance public IP|
|public\_key|The public key data in PEM format|
|public\_key\_openssh| The public key data in OpenSSH authorized_keys format|
|subnet\_id|Subnet ID instance is connected to|
|vpc_id|VPC ID for instance|
|zzz\_ec2\_ssh|SSH command to connect to instance|

## Authors

[Darrell Davis](https://github.com/darrelldavis)

## License
MIT Licensed. See LICENSE for full details.

