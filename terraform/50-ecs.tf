resource "aws_ecs_cluster" "runners" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.main.arn
      logging    = "NONE"
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "runners" {
  cluster_name       = aws_ecs_cluster.runners.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_cloudwatch_log_group" "runner" {
  name              = "/ecs/${var.name_prefix}/runner"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_ecs_task_definition" "runner" {
  family                   = "${var.name_prefix}-runner"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.runner_cpu
  memory                   = var.runner_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.runner_task.arn

  ephemeral_storage {
    size_in_gib = var.ephemeral_storage_gb
  }

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "runner"
      image     = var.runner_image_uri
      essential = true
      # JIT config injected per-task by the scale-up Lambda via overrides.
      environment = [
        { name = "AWS_REGION", value = var.region },
        # cosign KMS URI for in-account signing (no public Sigstore).
        { name = "SIGNING_KMS_URI", value = "awskms:///${aws_kms_alias.signing.name}" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.runner.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "runner"
        }
      }
      # Drop all Linux capabilities; rootless BuildKit needs none of them.
      linuxParameters = {
        initProcessEnabled = true
      }
      readonlyRootFilesystem = false # build scratch needs a writable FS
    }
  ])
}
