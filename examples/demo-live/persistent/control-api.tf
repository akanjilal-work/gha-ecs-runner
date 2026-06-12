# The control interface for the live demo. Always on, scales to zero. Holds the
# GitHub App credential and read only permissions, and exposes a public address
# the demo page calls to start a build and to read its live state.

variable "control_app_url" {
  description = "Public URL of the deployed demo application (the ALB)."
  type        = string
  default     = ""
}
variable "github_app_id" {
  type    = string
  default = "4030957"
}
variable "github_installation_id" {
  type    = string
  default = "139681091"
}
variable "demo_repo_owner" {
  type    = string
  default = "akanjilal-work"
}
variable "demo_repo_name" {
  type    = string
  default = "gha-ecs-runner-demo"
}
variable "daily_build_cap" {
  type    = number
  default = 20
}

data "archive_file" "control_api" {
  type        = "zip"
  source_dir  = "${path.module}/../control-api/build"
  output_path = "${path.module}/../control-api/build.zip"
}

resource "aws_iam_role" "control_api" {
  name               = "${local.prefix}-control-api"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy_attachment" "control_api_basic" {
  role       = aws_iam_role.control_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
data "aws_iam_policy_document" "control_api" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app_key.arn]
  }
  statement {
    actions   = ["ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:DescribeImages", "ecr:ListImages"]
    resources = [aws_ecr_repository.app.arn]
  }
  statement {
    actions   = ["logs:FilterLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/${local.prefix}/*"]
  }
  statement {
    actions   = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.demostate.arn]
  }
}
resource "aws_iam_role_policy" "control_api" {
  name   = "control"
  role   = aws_iam_role.control_api.id
  policy = data.aws_iam_policy_document.control_api.json
}

resource "aws_lambda_function" "control_api" {
  function_name    = "${local.prefix}-control-api"
  role             = aws_iam_role.control_api.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.control_api.output_path
  source_code_hash = data.archive_file.control_api.output_base64sha256
  timeout          = 30
  memory_size      = 256
  environment {
    variables = {
      GITHUB_APP_ID      = var.github_app_id
      APP_KEY_SECRET_ARN = aws_secretsmanager_secret.app_key.arn
      INSTALLATION_ID    = var.github_installation_id
      REPO_OWNER         = var.demo_repo_owner
      REPO_NAME          = var.demo_repo_name
      WORKFLOW_FILE      = "build-and-push.yml"
      CLUSTER            = local.prefix
      RUNNER_FAMILY      = "${local.prefix}-runner"
      RUNNER_LOG_GROUP   = "/${local.prefix}/runner"
      APP_URL            = var.control_app_url
      ECR_REPO           = "${local.prefix}/app"
      STATE_TABLE        = aws_dynamodb_table.demostate.name
      DAILY_CAP          = tostring(var.daily_build_cap)
    }
  }
}

# Public ingress via API Gateway (this account's org blocks public Lambda
# Function URLs, but a public HTTP API is permitted, same as the webhook).
resource "aws_apigatewayv2_api" "control_api" {
  name          = "${local.prefix}-control-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
  }
}
resource "aws_apigatewayv2_integration" "control_api" {
  api_id                 = aws_apigatewayv2_api.control_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.control_api.invoke_arn
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "trigger" {
  api_id    = aws_apigatewayv2_api.control_api.id
  route_key = "POST /trigger"
  target    = "integrations/${aws_apigatewayv2_integration.control_api.id}"
}
resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.control_api.id
  route_key = "GET /status"
  target    = "integrations/${aws_apigatewayv2_integration.control_api.id}"
}
resource "aws_apigatewayv2_stage" "control_api" {
  api_id      = aws_apigatewayv2_api.control_api.id
  name        = "$default"
  auto_deploy = true
}
resource "aws_lambda_permission" "control_api_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.control_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.control_api.execution_arn}/*/*"
}

output "control_api_url" { value = aws_apigatewayv2_api.control_api.api_endpoint }
