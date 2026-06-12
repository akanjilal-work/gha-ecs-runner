# Control plane: webhook (verify + enqueue) and scale-up (JIT + RunTask).
# Handlers are the reference implementations, staged by ./stage_lambdas.sh.

data "archive_file" "webhook" {
  type        = "zip"
  source_dir  = "${path.module}/build/webhook"
  output_path = "${path.module}/build/webhook.zip"
}
data "archive_file" "scaleup" {
  type        = "zip"
  source_dir  = "${path.module}/build/scaleup"
  output_path = "${path.module}/build/scaleup.zip"
}

resource "aws_cloudwatch_log_group" "webhook" {
  name              = "/aws/lambda/${local.prefix}-webhook"
  retention_in_days = 7
}
resource "aws_cloudwatch_log_group" "scaleup" {
  name              = "/aws/lambda/${local.prefix}-scaleup"
  retention_in_days = 7
}

resource "aws_lambda_function" "webhook" {
  function_name    = "${local.prefix}-webhook"
  role             = data.aws_iam_role.webhook_lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.webhook.output_path
  source_code_hash = data.archive_file.webhook.output_base64sha256
  timeout          = 10
  environment {
    variables = {
      JOB_QUEUE_URL      = aws_sqs_queue.jobs.url
      WEBHOOK_SECRET_ARN = data.aws_secretsmanager_secret.webhook.arn
      REQUIRED_LABELS    = var.required_labels
    }
  }
  depends_on = [aws_cloudwatch_log_group.webhook]
}

resource "aws_lambda_function" "scaleup" {
  function_name                  = "${local.prefix}-scaleup"
  role                           = data.aws_iam_role.scaleup_lambda.arn
  runtime                        = "python3.12"
  handler                        = "handler.handler"
  filename                       = data.archive_file.scaleup.output_path
  source_code_hash               = data.archive_file.scaleup.output_base64sha256
  timeout                        = 30
  reserved_concurrent_executions = 2 # hard ceiling on simultaneous runner launches
  environment {
    variables = {
      ECS_CLUSTER               = aws_ecs_cluster.this.name
      TASK_DEFINITION           = aws_ecs_task_definition.runner.arn
      CONTAINER_NAME            = "runner"
      SUBNET_IDS                = join(",", aws_subnet.private[*].id)
      SECURITY_GROUP_IDS        = aws_security_group.runner.id
      RUNNER_GROUP_ID           = "1"
      GITHUB_APP_ID             = var.github_app_id
      GITHUB_APP_KEY_SECRET_ARN = data.aws_secretsmanager_secret.app_key.arn
      GITHUB_API_URL            = var.github_api_url
      USE_FARGATE_SPOT          = "false"
      LAUNCH_TYPE               = "EC2"
    }
  }
  depends_on = [aws_cloudwatch_log_group.scaleup]
}

resource "aws_lambda_event_source_mapping" "jobs" {
  event_source_arn = aws_sqs_queue.jobs.arn
  function_name    = aws_lambda_function.scaleup.arn
  batch_size       = 1
  function_response_types = ["ReportBatchItemFailures"]
}
