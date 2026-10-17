output "evidence_bucket_name" {
  description = "Supply-chain evidence bucket (LocalStack)."
  value       = module.platform.evidence_bucket_name
}

output "api_log_group_name" {
  description = "CloudWatch log group (LocalStack)."
  value       = module.platform.api_log_group_name
}
