# Remote state in a LocalStack S3 bucket, with S3 native lock files.
# The bucket is created by scripts/tofu_localstack_check.sh using awslocal
# (inside the LocalStack container) - not by `tofu apply`.
bucket                      = "healthqueue-tfstate-local"
key                         = "healthqueue/local/platform.tfstate"
region                      = "us-east-1"
encrypt                     = true
use_lockfile                = true
use_path_style              = true
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_region_validation      = true
access_key                  = "test"
secret_key                  = "test"
endpoints = {
  s3  = "http://localhost:4566"
  sts = "http://localhost:4566"
}
