# --- SQS: decouple webhook ingestion from runner provisioning ----------------
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.main.arn
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.name_prefix}-jobs"
  visibility_timeout_seconds = 120 # >= scale-up Lambda timeout
  kms_master_key_id          = aws_kms_key.main.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
}

# --- Lambda packaging --------------------------------------------------------
data "archive_file" "webhook" {
  type        = "zip"
  source_dir  = "${path.module}/../build/webhook"
  output_path = "${path.module}/../build/webhook.zip"
}

data "archive_file" "scaleup" {
  type        = "zip"
  source_dir  = "${path.module}/../build/scale_up"
  output_path = "${path.module}/../build/scale_up.zip"
}

resource "aws_cloudwatch_log_group" "webhook" {
  name              = "/aws/lambda/${var.name_prefix}-webhook"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "scaleup" {
  name              = "/aws/lambda/${var.name_prefix}-scaleup"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

# Both Lambdas run INSIDE the VPC with egress restricted to the VPC CIDR, so
# all their traffic (Secrets, SQS, ECS, STS, KMS, and GHES) stays private.
resource "aws_lambda_function" "webhook" {
  function_name    = "${var.name_prefix}-webhook"
  role             = aws_iam_role.webhook_lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.webhook.output_path
  source_code_hash = data.archive_file.webhook.output_base64sha256
  timeout          = 10
  memory_size      = 256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      JOB_QUEUE_URL      = aws_sqs_queue.jobs.url
      WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.webhook.arn
      REQUIRED_LABELS    = join(",", var.required_labels)
    }
  }
}

resource "aws_lambda_function" "scaleup" {
  function_name                  = "${var.name_prefix}-scaleup"
  role                           = aws_iam_role.scaleup_lambda.arn
  runtime                        = "python3.12"
  handler                        = "handler.handler"
  filename                       = data.archive_file.scaleup.output_path
  source_code_hash               = data.archive_file.scaleup.output_base64sha256
  timeout                        = 60
  memory_size                    = 256
  reserved_concurrent_executions = var.max_concurrent_runners # hard cap

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      ECS_CLUSTER               = aws_ecs_cluster.runners.arn
      TASK_DEFINITION           = aws_ecs_task_definition.runner.arn
      CONTAINER_NAME            = "runner"
      SUBNET_IDS                = join(",", var.private_subnet_ids)
      SECURITY_GROUP_IDS        = aws_security_group.runner.id
      RUNNER_GROUP_ID           = tostring(var.runner_group_id)
      GITHUB_APP_ID             = var.github_app_id
      GITHUB_APP_KEY_SECRET_ARN = aws_secretsmanager_secret.app_key.arn
      GITHUB_API_URL            = var.github_api_url # in-VPC GHES for no-public
      USE_FARGATE_SPOT          = tostring(var.use_fargate_spot)
    }
  }
}

resource "aws_lambda_event_source_mapping" "jobs" {
  event_source_arn                   = aws_sqs_queue.jobs.arn
  function_name                      = aws_lambda_function.scaleup.arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

# ============================================================================
# PRIVATE webhook ingress (REST API, PRIVATE endpoint type).
# Reachable ONLY through the execute-api VPC endpoint -> the in-VPC GitHub
# Enterprise Server posts here over PrivateLink. There is NO public URL.
# ============================================================================
resource "aws_api_gateway_rest_api" "webhook" {
  name = "${var.name_prefix}-webhook"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [aws_vpc_endpoint.execute_api.id]
  }
}

# Resource policy: deny anything not arriving via OUR execute-api endpoint.
data "aws_iam_policy_document" "api_resource" {
  statement {
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.webhook.execution_arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
  statement {
    effect    = "Deny"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.webhook.execution_arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      values   = [aws_vpc_endpoint.execute_api.id]
    }
  }
}

resource "aws_api_gateway_rest_api_policy" "webhook" {
  rest_api_id = aws_api_gateway_rest_api.webhook.id
  policy      = data.aws_iam_policy_document.api_resource.json
}

resource "aws_api_gateway_resource" "webhook" {
  rest_api_id = aws_api_gateway_rest_api.webhook.id
  parent_id   = aws_api_gateway_rest_api.webhook.root_resource_id
  path_part   = "webhook"
}

resource "aws_api_gateway_method" "webhook" {
  rest_api_id   = aws_api_gateway_rest_api.webhook.id
  resource_id   = aws_api_gateway_resource.webhook.id
  http_method   = "POST"
  authorization = "NONE" # auth is the HMAC signature check inside the Lambda
}

resource "aws_api_gateway_integration" "webhook" {
  rest_api_id             = aws_api_gateway_rest_api.webhook.id
  resource_id             = aws_api_gateway_resource.webhook.id
  http_method             = aws_api_gateway_method.webhook.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.webhook.invoke_arn
}

resource "aws_api_gateway_deployment" "webhook" {
  rest_api_id = aws_api_gateway_rest_api.webhook.id
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.webhook.id,
      aws_api_gateway_method.webhook.id,
      aws_api_gateway_integration.webhook.id,
      aws_api_gateway_rest_api_policy.webhook.policy,
    ]))
  }
  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "default" {
  rest_api_id   = aws_api_gateway_rest_api.webhook.id
  deployment_id = aws_api_gateway_deployment.webhook.id
  stage_name    = "prod"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId = "$context.requestId", ip = "$context.identity.sourceIp",
      status = "$context.status", routeKey = "$context.resourcePath"
    })
  }
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigw/${var.name_prefix}-webhook"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.webhook.execution_arn}/*/*"
}
