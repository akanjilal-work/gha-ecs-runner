output "webhook_url" {
  description = "Set this as the GitHub App webhook URL."
  value       = "${aws_apigatewayv2_api.webhook.api_endpoint}/webhook"
}
output "app_url" {
  description = "Public URL of the deployed app behind the ALB."
  value       = "http://${aws_lb.app.dns_name}"
}
output "cluster" { value = aws_ecs_cluster.this.name }
output "app_service" { value = aws_ecs_service.app.name }
output "runner_taskdef_arn" { value = aws_ecs_task_definition.runner.arn }
output "vpc_id" { value = aws_vpc.this.id }
output "private_subnets" { value = aws_subnet.private[*].id }
output "runner_security_group" { value = aws_security_group.runner.id }
