# The ephemeral runner task definition. Each queued job runs ONE of these in a
# private subnet, builds rootless, signs with the in-account KMS key, and exits.

resource "aws_cloudwatch_log_group" "runner" {
  name              = "/${local.prefix}/runner"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "runner" {
  family                   = "${local.prefix}-runner"
  requires_compatibilities = ["EC2"] # Fargate cannot run rootless BuildKit
  network_mode             = "awsvpc"
  cpu                      = var.runner_cpu
  memory                   = var.runner_memory
  execution_role_arn       = data.aws_iam_role.exec.arn
  task_role_arn            = data.aws_iam_role.runner_task.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = "runner"
    image     = "${data.aws_ecr_repository.runner.repository_url}:latest"
    essential = true
    # EC2 only. Privileged removes the seccomp restriction that otherwise blocks
    # the unprivileged user namespace rootless BuildKit needs. The build process
    # itself still runs as the non-root runner user inside the container.
    privileged = true
    environment = [
      { name = "SIGNING_KMS_URI", value = "awskms:///alias/${local.prefix}-signing" },
      { name = "AWS_REGION", value = local.region },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.runner.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "runner"
      }
    }
  }])
}
