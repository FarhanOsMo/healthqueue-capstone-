module "platform" {
  source = "../../modules/healthqueue-platform"

  environment                 = "production"
  aws_region                  = var.aws_region
  github_repository           = var.github_repository
  create_github_oidc_provider = var.create_github_oidc_provider
  log_retention_days          = 90
}
