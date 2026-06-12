# Deploy configuration the pipeline's deploy job reads (so the workflow holds no
# ARNs). Written under /<prefix>/deploy/* which the runner task role can read.

locals {
  deploy_params = {
    cluster        = aws_ecs_cluster.this.name
    service        = aws_ecs_service.app.name
    task_family    = aws_ecs_task_definition.app.family
    container_name = "app"
    exec_role_arn  = data.aws_iam_role.exec.arn
    task_role_arn  = data.aws_iam_role.app_task.arn
    log_group      = aws_cloudwatch_log_group.app.name
    subnet_ids     = join(",", aws_subnet.private[*].id)
    security_group = aws_security_group.app.id
  }
}

resource "aws_ssm_parameter" "deploy" {
  for_each  = local.deploy_params
  name      = "/${local.prefix}/deploy/${each.key}"
  type      = "String"
  value     = each.value
  overwrite = true
}

# Runtime endpoints, so the control interface and the apply job always know the
# current application and webhook addresses even after the environment is
# destroyed and recreated.
resource "aws_ssm_parameter" "runtime_app_url" {
  name      = "/${local.prefix}/runtime/app_url"
  type      = "String"
  value     = "http://${aws_lb.app.dns_name}/"
  overwrite = true
}
resource "aws_ssm_parameter" "runtime_webhook_url" {
  name      = "/${local.prefix}/runtime/webhook_url"
  type      = "String"
  value     = "${aws_apigatewayv2_api.webhook.api_endpoint}/webhook"
  overwrite = true
}
