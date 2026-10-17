variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "The only AWS account ID this configuration may touch (12 digits)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "The aws_account_id value must be a 12-digit AWS account ID."
  }
}

variable "github_repository" {
  description = "owner/name of the GitHub repository."
  type        = string
  default     = "FarhanOsMo/healthqueue-capstone-"
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}
