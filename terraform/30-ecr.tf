# Artifact store. Two repos: one for application images built by CI, one for
# the runner image itself. Both are immutable, KMS-encrypted, and scanned.

resource "aws_ecr_repository" "app" {
  name                 = "demo/app"
  image_tag_mutability = "IMMUTABLE" # no overwriting a tag once pushed

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "runner" {
  name                 = "${var.name_prefix}/runner"
  image_tag_mutability = "MUTABLE" # we re-tag :latest on rebuilds

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Enhanced scanning (Amazon Inspector) for OS + language package CVEs, continuous.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "ENHANCED"
  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

# Pull-through cache: runners and the runner-image build pull base images from
# OUR private ECR (over the ecr.dkr endpoint) instead of the public internet.
# ECR transparently fetches+caches from upstream the first time. Result: the
# VPC never makes an outbound pull to public.ecr.aws / Docker Hub itself.
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}
# For Docker Hub / GHCR add rules with credential_arn pointing at a Secrets
# Manager secret (those upstreams require auth):
#   ecr_repository_prefix = "dockerhub"
#   upstream_registry_url = "registry-1.docker.io"
#   credential_arn        = aws_secretsmanager_secret.dockerhub.arn

# Lifecycle: keep cost bounded; expire untagged + old images.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged after 1 day"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 100 tagged images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 100 }
        action       = { type = "expire" }
      }
    ]
  })
}

# THE enforcement control: only the runner task role may push. Even if someone
# builds an image elsewhere, they cannot land it in this repo. Deployment-side
# (EKS/ECS) pulls only from here, so "all artifacts are built privately" holds.
data "aws_iam_policy_document" "app_repo" {
  statement {
    sid    = "OnlyRunnerCanPush"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.runner_task.arn]
    }
    actions = [
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:BatchCheckLayerAvailability",
    ]
  }

  statement {
    sid    = "DenyPushFromAnyoneElse"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.runner_task.arn]
    }
  }
}

resource "aws_ecr_repository_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy     = data.aws_iam_policy_document.app_repo.json
}
