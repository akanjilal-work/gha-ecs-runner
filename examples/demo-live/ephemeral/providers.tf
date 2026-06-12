# Ephemeral tier: stood up on demand, torn down after the idle window. Holds the
# costly bits -- VPC + NAT, the public webhook ingress, the control plane, the
# runner task definition, and the ALB-fronted app service. Remote state lives in
# the S3 bucket the persistent stack created (partial backend config at init).

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "gha-ecs-runner-demo"
      ManagedBy = "terraform"
      Stack     = "ephemeral"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  prefix     = var.name_prefix
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)
}

# --- references to persistent resources (by stable name) ----------------------
data "aws_iam_role" "runner_task" { name = "${local.prefix}-runner-task" }
data "aws_iam_role" "exec" { name = "${local.prefix}-exec" }
data "aws_iam_role" "app_task" { name = "${local.prefix}-app-task" }
data "aws_iam_role" "webhook_lambda" { name = "${local.prefix}-webhook-lambda" }
data "aws_iam_role" "scaleup_lambda" { name = "${local.prefix}-scaleup-lambda" }

data "aws_ecr_repository" "app" { name = "${local.prefix}/app" }
data "aws_ecr_repository" "runner" { name = "${local.prefix}/runner" }

data "aws_kms_alias" "signing" { name = "alias/${local.prefix}-signing" }

data "aws_secretsmanager_secret" "app_key" { name = "${local.prefix}/github-app-key" }
data "aws_secretsmanager_secret" "webhook" { name = "${local.prefix}/webhook-secret" }
