terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Use a remote state backend with encryption + locking in real deployments.
  # backend "s3" {
  #   bucket         = "my-tfstate"
  #   key            = "gha-ecs-runner/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "tf-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "gha-ecs-runner"
      ManagedBy = "terraform"
      Component = "ci-build-plane"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
