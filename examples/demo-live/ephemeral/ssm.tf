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
