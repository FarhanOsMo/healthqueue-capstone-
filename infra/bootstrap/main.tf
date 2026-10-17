# One-time bootstrap: the S3 bucket that stores OpenTofu remote state.
#
# Chicken-and-egg: this tiny config uses LOCAL state, because the remote-state
# bucket does not exist yet. It is run once, manually, by an administrator,
# after review - never by CI. Every other root module then uses the bucket.
terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
  }
}

variable "aws_region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "The only AWS account this bootstrap may touch."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "The aws_account_id value must be a 12-digit AWS account ID."
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project   = "healthqueue"
      ManagedBy = "opentofu"
      Purpose   = "opentofu-remote-state"
    }
  }
}

resource "aws_s3_bucket" "state" {
  bucket = "healthqueue-tfstate-${var.aws_account_id}"

  lifecycle {
    prevent_destroy = true # losing state means losing track of real infrastructure
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # every state write is kept -> point-in-time recovery
  }
}

# Customer-managed key: rotation, key policy and CloudTrail audit stay under our control.
resource "aws_kms_key" "state" {
  description             = "HealthQueue OpenTofu state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "state" {
  name          = "alias/healthqueue-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms" # state can contain sensitive values
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}

output "state_bucket" {
  description = "Use this as `bucket` in environments/*/backend.hcl."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "Use this as `kms_key_id` in environments/*/backend.hcl."
  value       = aws_kms_key.state.arn
}
