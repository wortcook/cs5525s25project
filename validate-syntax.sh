#!/bin/bash

# Simple Terraform syntax validation without cloud dependencies
# This script checks the basic HCL syntax

echo "Checking Terraform syntax..."

# Create a temporary directory for isolated validation
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Copy the module files
cp -r /Users/thomasjones/workspace/cs5525s25project/modules ./
cp /Users/thomasjones/workspace/cs5525s25project/variables.tf ./

# Create a minimal test configuration
cat > test-main.tf << 'EOF'
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# Minimal test of the cloud-run-service module
module "test_service" {
  source                = "./modules/cloud-run-service"
  service_name          = "test-service"
  region               = "us-central1"
  image_name           = "gcr.io/cloudrun/hello"
  port                 = 8080
  service_account_email = "test@example.com"
  vpc_connector_id     = "test-connector"
  environment_variables = {}
  gcs_bucket_name      = "test-bucket"
  model_mount_path     = "/storage/models"
}
EOF

# Validate the configuration
echo "Running terraform fmt..."
terraform fmt -check=true -diff=true

echo "Running terraform validate..."
terraform init -backend=false
terraform validate

# Clean up
cd /
rm -rf "$TEMP_DIR"

echo "Validation complete."
