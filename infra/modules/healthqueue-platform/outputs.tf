output "kms_key_arn" {
  description = "ARN of the platform KMS key."
  value       = aws_kms_key.platform.arn
}

output "evidence_bucket_name" {
  description = "Name of the supply-chain evidence bucket."
  value       = aws_s3_bucket.evidence.bucket
}

output "evidence_bucket_arn" {
  description = "ARN of the supply-chain evidence bucket."
  value       = aws_s3_bucket.evidence.arn
}

output "api_log_group_name" {
  description = "CloudWatch log group for API logs."
  value       = aws_cloudwatch_log_group.api.name
}

output "github_evidence_role_arn" {
  description = "Role ARN the release workflow assumes via OIDC (set as repo variable AWS_EVIDENCE_ROLE_ARN)."
  value       = aws_iam_role.github_evidence_uploader.arn
}
