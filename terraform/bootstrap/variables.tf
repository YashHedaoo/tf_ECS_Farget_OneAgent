variable "aws_region" {
  type        = string
  description = "AWS region for the state bucket and lock table"
  default     = "us-east-1"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique name for the S3 bucket that stores Terraform state"
}

variable "lock_table_name" {
  type        = string
  description = "Name for the DynamoDB table used for state locking"
  default     = "terraform-locks"
}
