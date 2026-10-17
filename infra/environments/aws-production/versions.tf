terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69" # exact version + checksums are pinned in .terraform.lock.hcl
    }
  }

  # Remote state in S3 with native S3 locking (no DynamoDB table needed).
  # Values live in backend.hcl so the same code can target different accounts:
  #   tofu init -backend-config=backend.hcl
  backend "s3" {}
}
