terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }

  # Same S3 backend type as production, pointed at LocalStack by backend.hcl.
  # This lets remote state + locking be tested for free.
  backend "s3" {}
}
