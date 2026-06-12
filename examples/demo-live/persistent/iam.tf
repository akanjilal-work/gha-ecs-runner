# Stable IAM roles. Kept in the persistent tier (roles are free and identity
# should be stable), so the ECR gate references the runner role directly and the
# ephemeral stack just passes these ARNs into task defs and Lambdas.
#
# Policies are scoped by the gha-demo-* naming convention rather than by resource
# reference, so there is no circular dependency with the ephemeral stack.

locals {
  sqs_arns  = ["arn:aws:sqs:${local.region}:${local.account_id}:${local.prefix}-jobs", "arn:aws:sqs:${local.region}:${local.account_id}:${local.prefix}-dlq"]
  secret_arn = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${local.prefix}/*"
  taskdef_arn = "arn:aws:ecs:${local.region}:${local.account_id}:task-definition/${local.prefix}-*"
  cluster_arn = "arn:aws:ecs:${local.region}:${local.account_id}:cluster/${local.prefix}"
  service_arn = "arn:aws:ecs:${local.region}:${local.account_id}:service/${local.prefix}/${local.prefix}-app"
  ssm_arn     = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${local.prefix}/*"
  logs_arn    = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/${local.prefix}/*"
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- ECS task execution role (pull image + write logs; used by ECS agent) -----
resource "aws_iam_role" "exec" {
  name               = "${local.prefix}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}
resource "aws_iam_role_policy_attachment" "exec_managed" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- App task role (the app itself needs nothing) -----------------------------
resource "aws_iam_role" "app_task" {
  name               = "${local.prefix}-app-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# --- Runner task role: build+push, sign, and deploy ---------------------------
resource "aws_iam_role" "runner_task" {
  name               = "${local.prefix}-runner-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "runner_task" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
      "ecr:DescribeImages", "ecr:ListImages",
    ]
    resources = [aws_ecr_repository.app.arn, aws_ecr_repository.runner.arn]
  }
  statement {
    sid       = "KmsSign"
    actions   = ["kms:Sign", "kms:Verify", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = [aws_kms_key.signing.arn]
  }
  statement {
    sid       = "EcsRegister"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition", "sts:GetCallerIdentity"]
    resources = ["*"]
  }
  statement {
    sid       = "EcsDeploy"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ecs:cluster"
      values   = [local.cluster_arn]
    }
  }
  statement {
    sid       = "PassRolesForDeploy"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.exec.arn, aws_iam_role.app_task.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    sid       = "ReadDeployConfig"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:CreateLogGroup"]
    resources = [local.logs_arn]
  }
}
resource "aws_iam_role_policy" "runner_task" {
  name   = "task"
  role   = aws_iam_role.runner_task.id
  policy = data.aws_iam_policy_document.runner_task.json
}

# --- Webhook Lambda role: verify + enqueue ------------------------------------
resource "aws_iam_role" "webhook_lambda" {
  name               = "${local.prefix}-webhook-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "webhook_basic" {
  role       = aws_iam_role.webhook_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
data "aws_iam_policy_document" "webhook_lambda" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = local.sqs_arns
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_arn]
  }
}
resource "aws_iam_role_policy" "webhook_lambda" {
  name   = "webhook"
  role   = aws_iam_role.webhook_lambda.id
  policy = data.aws_iam_policy_document.webhook_lambda.json
}

# --- Scale-up Lambda role: JIT + RunTask --------------------------------------
resource "aws_iam_role" "scaleup_lambda" {
  name               = "${local.prefix}-scaleup-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "scaleup_basic" {
  role       = aws_iam_role.scaleup_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
data "aws_iam_policy_document" "scaleup_lambda" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = local.sqs_arns
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_arn]
  }
  statement {
    actions   = ["ecs:RunTask"]
    resources = [local.taskdef_arn]
  }
  statement {
    # RunTask propagates tags onto the task, which requires TagResource.
    actions   = ["ecs:TagResource"]
    resources = ["arn:aws:ecs:${local.region}:${local.account_id}:task/${local.prefix}/*"]
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.runner_task.arn, aws_iam_role.exec.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role_policy" "scaleup_lambda" {
  name   = "scaleup"
  role   = aws_iam_role.scaleup_lambda.id
  policy = data.aws_iam_policy_document.scaleup_lambda.json
}
