# Real AWS. Credentials come from the environment (AWS SSO or an OIDC role),
# never from this repository. Nothing in this project runs `tofu apply` here;
# see docs/runbooks/opentofu.md for the guarded manual procedure.
provider "aws" {
  region = var.aws_region

  # Safety net: refuse to run against any account except the expected one.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project            = "healthqueue"
      Environment        = "production"
      ManagedBy          = "opentofu"
      Repository         = var.github_repository
      DataClassification = "no-phi" # these resources never store patient data
      CostCenter         = "platform-engineering"
    }
  }
}
