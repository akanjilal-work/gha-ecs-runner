# Persistent tier of the live demo: the always-on, near-zero-cost foundation that
# survives across ephemeral-environment cycles -- ECR, the KMS signing key, the
# stable IAM roles, remote state, and the bootstrap that builds the runner image.
#
# Local state (kept out of git): this stack is applied by hand from a trusted
# machine. The ephemeral stack uses the S3 backend this stack creates.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "gha-ecs-runner-demo"
      ManagedBy = "terraform"
      Stack     = "persistent"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  prefix     = var.name_prefix
}
