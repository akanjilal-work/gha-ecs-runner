output "region" { value = local.region }
output "account_id" { value = local.account_id }

output "ecr_app_repo" { value = aws_ecr_repository.app.repository_url }
output "ecr_runner_repo" { value = aws_ecr_repository.runner.repository_url }
output "registry" { value = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com" }

output "signing_kms_arn" { value = aws_kms_key.signing.arn }
output "signing_kms_uri" { value = "awskms:///alias/${local.prefix}-signing" }

output "runner_task_role_arn" { value = aws_iam_role.runner_task.arn }
output "exec_role_arn" { value = aws_iam_role.exec.arn }
output "app_task_role_arn" { value = aws_iam_role.app_task.arn }
output "webhook_lambda_role_arn" { value = aws_iam_role.webhook_lambda.arn }
output "scaleup_lambda_role_arn" { value = aws_iam_role.scaleup_lambda.arn }

output "tfstate_bucket" { value = aws_s3_bucket.tfstate.id }
output "tflock_table" { value = aws_dynamodb_table.tflock.name }
output "demostate_table" { value = aws_dynamodb_table.demostate.name }

output "runner_image_codebuild" { value = aws_codebuild_project.runner_image.name }
