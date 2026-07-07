output "state_bucket_name" {
  description = "Use as `bucket` in ../backend.hcl"
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "Use as `dynamodb_table` in ../backend.hcl"
  value       = aws_dynamodb_table.tflock.name
}
