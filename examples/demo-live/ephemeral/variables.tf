variable "region" {
  type    = string
  default = "ca-central-1"
}
variable "name_prefix" {
  type    = string
  default = "gha-demo"
}
variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "github_app_id" {
  type        = string
  description = "GitHub App ID used to mint JIT runner configs."
}
variable "github_api_url" {
  type    = string
  default = "https://api.github.com"
}
variable "required_labels" {
  type    = string
  default = "self-hosted,ecs,linux,x64"
}

variable "runner_instance_type" {
  type    = string
  default = "t3.medium"
}
variable "runner_cpu" {
  type    = number
  default = 2048
}
variable "runner_memory" {
  type    = number
  default = 3072
}
variable "app_cpu" {
  type    = number
  default = 256
}
variable "app_memory" {
  type    = number
  default = 512
}
variable "app_image_tag" {
  type    = string
  default = "latest"
}
