output "webhook_url" {
  description = "Private REST API URL. Resolves only inside the VPC via the execute-api endpoint; set as the GHES webhook Payload URL."
  value       = "https://${aws_api_gateway_rest_api.webhook.id}.execute-api.${var.region}.amazonaws.com/${aws_api_gateway_stage.default.stage_name}/webhook"
}

output "signing_kms_key_arn" {
  description = "Asymmetric CMK cosign signs with (verify side uses the same key / its public key)."
  value       = aws_kms_key.signing.arn
}

output "signing_kms_uri" {
  description = "cosign KMS URI for sign/verify, e.g. cosign verify --key <this>."
  value       = "awskms:///${aws_kms_alias.signing.name}"
}

output "webhook_secret_arn" {
  value = aws_secretsmanager_secret.webhook.arn
}

output "github_app_key_secret_arn" {
  description = "Put the GitHub App PEM here via put-secret-value."
  value       = aws_secretsmanager_secret.app_key.arn
}

output "ecr_app_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecr_runner_repository_url" {
  value = aws_ecr_repository.runner.repository_url
}

output "ecs_cluster_arn" {
  value = aws_ecs_cluster.runners.arn
}

output "runner_task_role_arn" {
  value = aws_iam_role.runner_task.arn
}
