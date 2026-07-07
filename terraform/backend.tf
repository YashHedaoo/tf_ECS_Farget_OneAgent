# Remote state backend (S3 + DynamoDB lock).
#
# Partial configuration on purpose: the bucket/table names are supplied at
# `terraform init` time so this file stays free of account-specific values.
#   - Local:  terraform init -backend-config=backend.hcl
#   - CI:     terraform init -backend-config="bucket=..." -backend-config=... (see deploy.yml)
#
# The bucket and DynamoDB table must exist first — create them once with the
# `bootstrap/` configuration (see README).
terraform {
  backend "s3" {}
}
