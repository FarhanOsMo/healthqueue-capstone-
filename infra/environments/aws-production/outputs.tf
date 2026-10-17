output "evidence_bucket_name" {
  description = "Supply-chain evidence bucket."
  value       = module.platform.evidence_bucket_name
}

output "api_log_group_name" {
  description = "CloudWatch log group for the API."
  value       = module.platform.api_log_group_name
}

output "github_evidence_role_arn" {
  description = "Set as GitHub repository variable AWS_EVIDENCE_ROLE_ARN."
  value       = module.platform.github_evidence_role_arn
}

output "kms_key_arn" {
  description = "Platform KMS key."
  value       = module.platform.kms_key_arn
}
