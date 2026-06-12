# Bootstrap: build the runner image with CodeBuild (no local Docker needed) and
# push it to the runner ECR repo. CodeBuild clones the public reference repo, so
# no source credentials are required.

resource "aws_iam_role" "codebuild_bootstrap" {
  name = "${local.prefix}-codebuild-bootstrap"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "codebuild_bootstrap" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/codebuild/${local.prefix}-*"]
  }
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.runner.arn]
  }
}
resource "aws_iam_role_policy" "codebuild_bootstrap" {
  name   = "bootstrap"
  role   = aws_iam_role.codebuild_bootstrap.id
  policy = data.aws_iam_policy_document.codebuild_bootstrap.json
}

resource "aws_codebuild_project" "runner_image" {
  name          = "${local.prefix}-runner-image"
  description   = "Builds and pushes the ephemeral runner image to ECR."
  service_role  = aws_iam_role.codebuild_bootstrap.arn
  build_timeout = 20

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required to run docker build
    environment_variable {
      name  = "RUNNER_REPO"
      value = aws_ecr_repository.runner.repository_url
    }
    environment_variable {
      name  = "REGISTRY"
      value = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
    }
    environment_variable {
      name  = "SRC"
      value = var.runner_repo_source
    }
  }

  source {
    type = "NO_SOURCE"
    buildspec = <<-EOT
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $REGISTRY
            - git clone --depth 1 "$SRC" src
        build:
          commands:
            - cd src/runner
            - docker build -t "$RUNNER_REPO:latest" .
            - docker push "$RUNNER_REPO:latest"
        post_build:
          commands:
            - echo "Pushed $RUNNER_REPO:latest"
    EOT
  }

  logs_config {
    cloudwatch_logs { group_name = "/aws/codebuild/${local.prefix}-runner-image" }
  }
}
