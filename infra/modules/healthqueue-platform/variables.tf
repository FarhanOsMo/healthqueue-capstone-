variable "project" {
  description = "Short project name used as a resource-name prefix."
  type        = string
  default     = "healthqueue"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project))
    error_message = "project must be 3-21 lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "Deployment environment (local, staging, production)."
  type        = string

  validation {
    condition     = contains(["local", "staging", "production"], var.environment)
    error_message = "environment must be one of: local, staging, production."
  }
}

variable "aws_region" {
  description = "AWS region the resources live in (used in KMS/log ARNs)."
  type        = string
}

variable "github_repository" {
  description = "owner/name of the GitHub repository allowed to assume the CI role."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the account-wide GitHub OIDC provider (only once per AWS account)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Must be a value CloudWatch accepts."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported retention value."
  }
}

variable "evidence_noncurrent_retention_days" {
  description = "How long overwritten/deleted evidence versions are kept before expiry."
  type        = number
  default     = 365

  validation {
    condition     = var.evidence_noncurrent_retention_days >= 30
    error_message = "Keep noncurrent evidence versions for at least 30 days."
  }
}
