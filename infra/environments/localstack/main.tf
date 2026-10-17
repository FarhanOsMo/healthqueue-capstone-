module "platform" {
  source = "../../modules/healthqueue-platform"

  environment                 = "local"
  aws_region                  = "us-east-1"
  github_repository           = "FarhanOsMo/healthqueue-capstone-"
  create_github_oidc_provider = true
  log_retention_days          = 7
}
