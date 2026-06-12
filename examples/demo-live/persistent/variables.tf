variable "region" {
  description = "AWS region for the demo."
  type        = string
  default     = "ca-central-1"
}

variable "name_prefix" {
  description = "Prefix for all demo resource names. Everything the convention-scoped IAM policies grant is gated on this prefix."
  type        = string
  default     = "gha-demo"
}

variable "runner_repo_source" {
  description = "Public git repo the bootstrap CodeBuild clones to build the runner image."
  type        = string
  default     = "https://github.com/akanjilal-work/gha-ecs-runner.git"
}
