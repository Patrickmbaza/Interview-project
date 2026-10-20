# Copy this file to backend.tf after creating the bucket and DynamoDB lock table.
# Keep backend.tf out of Git; it can include organization-specific names.
terraform {
  backend "s3" {
    bucket         = "domalak-state-bucket"
    key            = "devops-microservice/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "domalak-lock-table"
    encrypt        = true
  }
}
