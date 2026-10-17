# HealthQueue platform foundation.
#
# Resources (all encrypted, private, tagged):
#   1. KMS customer-managed key  - one key encrypts the bucket and the log group
#   2. S3 bucket                 - immutable archive for supply-chain evidence
#                                  (SBOMs, scan reports, attestations) and audit exports
#   3. CloudWatch log group      - API application logs, fixed retention
#   4. IAM role for GitHub OIDC  - lets the release workflow upload evidence
#                                  WITHOUT any long-lived AWS keys in GitHub
#
# The Kubernetes cluster itself is intentionally NOT provisioned here: the
# reference implementation runs on kind locally (see ADR-0003 / ADR-0004).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# ---------------------------------------------------------------- 1. KMS ---
data "aws_iam_policy_document" "kms" {
  # Account administrators keep control of the key (prevents a locked-out key).
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch Logs may use the key, but only for this project's log group.
  statement {
    sid = "AllowCloudWatchLogsForThisLogGroup"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/healthqueue/${var.environment}/api"]
    }
  }
}

resource "aws_kms_key" "platform" {
  description             = "${local.name} encryption key (evidence bucket + logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.platform.key_id
}

# ------------------------------------------------------ 2. Evidence bucket ---
resource "aws_s3_bucket" "evidence" {
  bucket = "${local.name}-evidence-${local.account_id}"
  # Protect audit evidence from an accidental `tofu destroy`.
  force_destroy = false
}

resource "aws_s3_bucket_ownership_controls" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  rule {
    object_ownership = "BucketOwnerEnforced" # disables ACLs entirely
  }
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.platform.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    id     = "tier-and-expire-evidence"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    noncurrent_version_expiration {
      noncurrent_days = var.evidence_noncurrent_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.evidence]
}

data "aws_iam_policy_document" "evidence_bucket" {
  # Refuse any request that is not over TLS.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.evidence.arn,
      "${aws_s3_bucket.evidence.arn}/*",
    ]
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

resource "aws_s3_bucket_policy" "evidence" {
  bucket     = aws_s3_bucket.evidence.id
  policy     = data.aws_iam_policy_document.evidence_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.evidence]
}

# ----------------------------------------------------------- 3. Log group ---
resource "aws_cloudwatch_log_group" "api" {
  name              = "/healthqueue/${var.environment}/api"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
}

# -------------------------------------------- 4. GitHub Actions OIDC role ---
# GitHub's OIDC provider can only exist once per AWS account, so it is optional.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only release runs from this repository's protected refs - not PRs, not forks.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/main",
        "repo:${var.github_repository}:ref:refs/tags/v*",
      ]
    }
  }
}

resource "aws_iam_role" "github_evidence_uploader" {
  name                 = "${local.name}-gha-evidence-uploader"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "evidence_upload" {
  # Write-only into one prefix: CI can add evidence but cannot delete or read
  # other objects, so a compromised workflow cannot erase history.
  statement {
    sid       = "PutEvidenceOnly"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.evidence.arn}/releases/*"]
  }
  statement {
    sid       = "UseProjectKeyForUploads"
    actions   = ["kms:GenerateDataKey", "kms:Encrypt"]
    resources = [aws_kms_key.platform.arn]
  }
}

resource "aws_iam_role_policy" "evidence_upload" {
  name   = "evidence-upload"
  role   = aws_iam_role.github_evidence_uploader.id
  policy = data.aws_iam_policy_document.evidence_upload.json
}
