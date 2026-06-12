# Artifact store + the registry gate. The app repo policy is the live demo's
# headline control: only the runner task role may push; everyone else is denied.

resource "aws_ecr_repository" "app" {
  name                 = "${local.prefix}/app"
  image_tag_mutability = "MUTABLE" # demo: re-triggering a build on the same SHA can re-push
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "runner" {
  name                 = "${local.prefix}/runner"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep storage tiny: expire untagged quickly, cap image count.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 20"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# THE enforcement control: only the runner task role can push to the app repo.
data "aws_iam_policy_document" "app_repo" {
  statement {
    sid       = "OnlyRunnerCanPush"
    effect    = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.runner_task.arn]
    }
    actions = [
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:BatchCheckLayerAvailability",
    ]
  }
  statement {
    sid       = "DenyPushFromAnyoneElse"
    effect    = "Deny"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
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
