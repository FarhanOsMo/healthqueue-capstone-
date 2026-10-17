# LocalStack only. The dummy "test" credentials are LocalStack's documented
# convention - they are not secrets and do not work against real AWS.
# Every endpoint is forced to a local URL (validated in variables.tf), so a
# mistake here cannot reach real AWS.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    cloudwatchlogs = var.localstack_endpoint
    iam            = var.localstack_endpoint
    kms            = var.localstack_endpoint
    s3             = var.localstack_endpoint
    sts            = var.localstack_endpoint
  }

  default_tags {
    tags = {
      Project     = "healthqueue"
      Environment = "local"
      ManagedBy   = "opentofu"
      Target      = "localstack"
    }
  }
}
