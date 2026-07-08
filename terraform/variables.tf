variable "aws_region" {
  type        = string
  description = "The AWS region to deploy resources in"
}

variable "cluster_name" {
  type        = string
  description = "The name of the AWS ECS Fargate Cluster"
}

variable "dynatrace_api_url" {
  type        = string
  description = "The Dynatrace environment API URL (e.g., https://<your-environment-id>.live.dynatrace.com)"
}

variable "dynatrace_paas_token" {
  type        = string
  description = "The Dynatrace PaaS token used to download the OneAgent installer"
  sensitive   = true
}
