#!/bin/bash
set -e

echo "Starting deployment preparation..."

# Install Lambda dependencies
echo "Installing Lambda dependencies..."
cd lambda/backup_validator && npm install --production && cd ../..
cd lambda/activity_predictor && npm install --production && cd ../..

# Package Lambda functions
echo "Packaging Lambda functions..."
cd lambda/backup_validator && zip -r ../../backup_validator.zip . && cd ../..
cd lambda/activity_predictor && zip -r ../../activity_predictor.zip . && cd ../..

# Validate terraform files
echo "Validating Terraform configuration..."
terraform fmt -check
terraform validate

# Check for sensitive data
echo "Checking for sensitive data..."
git grep -l 'TODO|FIXME|HACK|PASSWORD|SECRET|PRIVATE_KEY'

echo "Deployment preparation complete!"
