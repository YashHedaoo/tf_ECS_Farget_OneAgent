resource "aws_ssm_parameter" "dynatrace_paas_token" {
  name        = "/dynatrace/paas_token"
  description = "Dynatrace PaaS Token for ECS Fargate OneAgent instrumentation"
  type        = "SecureString"
  value       = var.dynatrace_paas_token

  tags = {
    Environment = "monitoring"
    ManagedBy   = "terraform"
  }
}

# OneAgent tenant token used by the app container to report data back to Dynatrace.
# Fetched from the connectioninfo API (see dynatrace.tf) and stored as a SecureString
# so it is injected into the task at launch instead of living in the task definition.
resource "aws_ssm_parameter" "dynatrace_tenant_token" {
  name        = "/dynatrace/tenant_token"
  description = "Dynatrace tenant token (DT_TENANTTOKEN) for OneAgent connectivity"
  type        = "SecureString"
  value       = local.dt_tenant_token

  tags = {
    Environment = "monitoring"
    ManagedBy   = "terraform"
  }
}
