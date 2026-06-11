variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "gha-ecs-runner"
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC to deploy runners and endpoints into."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets (no IGW route) for Fargate runners, Lambdas, and VPC endpoints."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR. Runner/Lambda egress is restricted to this range only (no internet)."
}

variable "github_api_url" {
  type        = string
  default     = "https://api.github.com"
  description = "GitHub API base. For a fully-private deployment point this at your in-VPC GitHub Enterprise Server, e.g. https://ghe.internal.example/api/v3."
}

variable "github_app_id" {
  type        = string
  description = "GitHub App ID used by the control plane."
}

variable "required_labels" {
  type        = list(string)
  default     = ["self-hosted", "ecs", "linux", "x64"]
  description = "Runner labels a job must request for us to provision capacity."
}

variable "runner_group_id" {
  type    = number
  default = 1
}

variable "runner_cpu" {
  type    = number
  default = 2048 # 2 vCPU
}

variable "runner_memory" {
  type    = number
  default = 4096 # 4 GB
}

variable "runner_image_uri" {
  type        = string
  description = "ECR URI of the runner image (built from runner/Dockerfile)."
}

variable "ephemeral_storage_gb" {
  type    = number
  default = 50 # bumped from the 20GB default for image-build scratch space
}

variable "use_fargate_spot" {
  type    = bool
  default = false
}

variable "max_concurrent_runners" {
  type        = number
  default     = 50
  description = "Reserved Lambda concurrency on scale-up == hard cap on parallel RunTask launches (cost + blast-radius guardrail)."
}

variable "log_retention_days" {
  type    = number
  default = 90
}
