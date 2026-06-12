# Durable secrets (stable across ephemeral-environment cycles): the GitHub App
# private key and the webhook secret. Created empty here; values are loaded
# out-of-band via the CLI, so no secret material lands in Terraform state.

resource "aws_secretsmanager_secret" "app_key" {
  name                    = "${local.prefix}/github-app-key"
  description             = "GitHub App private key (PEM) for JIT runner registration"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "webhook" {
  name                    = "${local.prefix}/webhook-secret"
  description             = "GitHub App webhook HMAC secret"
  recovery_window_in_days = 0
}

output "app_key_secret_arn" { value = aws_secretsmanager_secret.app_key.arn }
output "webhook_secret_arn" { value = aws_secretsmanager_secret.webhook.arn }
