terraform {
  required_version = ">= 1.10.0" # S3 backend native locking (use_lockfile) needs OpenTofu >= 1.10

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}
