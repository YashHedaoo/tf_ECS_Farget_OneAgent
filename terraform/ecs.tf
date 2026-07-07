# Data sources to fetch default VPC and subnet configurations
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# CloudWatch Log Group for ECS logs
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/${var.cluster_name}-logs"
  retention_in_days = 7
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.cluster_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Attach standard execution policy
resource "aws_iam_role_policy_attachment" "ecs_execution_standard" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# IAM Policy to allow reading SSM secrets
resource "aws_iam_policy" "ecs_ssm_access" {
  name        = "${var.cluster_name}-ecs-ssm-access"
  description = "Allows ECS execution role to retrieve Dynatrace secrets from SSM Parameter Store"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter"
        ]
        Resource = [
          aws_ssm_parameter.dynatrace_paas_token.arn,
          aws_ssm_parameter.dynatrace_tenant_token.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_ssm" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = aws_iam_policy.ecs_ssm_access.arn
}

# IAM Role for Task Process
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.cluster_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Security Group for ECS Task
resource "aws_security_group" "ecs_service_sg" {
  name        = "${var.cluster_name}-service-sg"
  description = "Allow inbound traffic on port 80 and all outbound"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-service-sg"
  }
}

# ECS Task Definition with Dynatrace Runtime Injection
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.cluster_name}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  volume {
    name = "oneagent"
  }

  container_definitions = jsonencode([
    {
      name       = "dynatrace-oneagent-init"
      image      = "alpine:latest"
      essential  = false
      entryPoint = ["sh", "-c"]
      command = [
        "set -e && apk add --no-cache wget unzip ca-certificates && ARCHIVE=$(mktemp) && wget -O $ARCHIVE \"$${DT_API_URL}/v1/deployment/installer/agent/unix/paas/latest?Api-Token=$${DT_PAAS_TOKEN}&flavor=musl&include=all\" && unzip -o -d /opt/dynatrace/oneagent $ARCHIVE && rm -f $ARCHIVE"
      ]
      environment = [
        {
          name  = "DT_API_URL"
          value = var.dynatrace_api_url
        }
      ]
      secrets = [
        {
          name      = "DT_PAAS_TOKEN"
          valueFrom = aws_ssm_parameter.dynatrace_paas_token.arn
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "oneagent"
          containerPath = "/opt/dynatrace/oneagent"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "dynatrace-init"
        }
      }
    },
    {
      name      = "app"
      image     = "nginx:alpine"
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "LD_PRELOAD"
          value = "/opt/dynatrace/oneagent/agent/lib64/liboneagentproc.so"
        },
        {
          name  = "DT_TENANT"
          value = local.dt_tenant
        },
        {
          name  = "DT_CONNECTION_POINT"
          value = local.dt_connection_point
        }
      ]
      secrets = [
        {
          name      = "DT_TENANTTOKEN"
          valueFrom = aws_ssm_parameter.dynatrace_tenant_token.arn
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "oneagent"
          containerPath = "/opt/dynatrace/oneagent"
          readOnly      = true
        }
      ]
      dependsOn = [
        {
          containerName = "dynatrace-oneagent-init"
          condition     = "COMPLETE"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])
}

# ECS Service running on Fargate
resource "aws_ecs_service" "app" {
  name            = "${var.cluster_name}-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_service_sg.id]
    assign_public_ip = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.ecs_execution_standard,
    aws_iam_role_policy_attachment.ecs_execution_ssm
  ]
}
