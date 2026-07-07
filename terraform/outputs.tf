output "ecs_cluster_name" {
  description = "The name of the (existing) ECS cluster the workload was deployed into"
  value       = var.cluster_name
}

output "ecs_cluster_arn" {
  description = "The ARN of the existing ECS cluster"
  value       = data.aws_ecs_cluster.main.arn
}

output "ecs_service_name" {
  description = "The name of the ECS service running the app"
  value       = aws_ecs_service.app.name
}

output "ecs_task_definition_arn" {
  description = "The ARN of the ECS task definition with Dynatrace instrumentation"
  value       = aws_ecs_task_definition.app.arn
}
