#!/bin/bash

# Generate terraform documentation using terraform-docs
terraform-docs markdown table --output-file README.md --output-mode inject .

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "README.md has been updated successfully"
    exit 0
else
    echo "Error: Failed to update README.md"
    exit 1
fi