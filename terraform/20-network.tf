# ============================================================================
# NO-PUBLIC NETWORK POSTURE
# ----------------------------------------------------------------------------
# * Runners and Lambdas live in PRIVATE subnets with no IGW/NAT route.
# * Egress is restricted to the VPC CIDR only -> they can reach the VPC
#   endpoints and in-VPC GitHub Enterprise Server, and NOTHING on the internet.
# * Every AWS service is consumed over an Interface/Gateway VPC endpoint
#   (PrivateLink). Endpoint policies pin usage to THIS account.
# * The webhook API is a PRIVATE REST API reachable only via the execute-api
#   endpoint (see 60-queue-lambda-apigw.tf).
# ============================================================================

# --- Security groups ---------------------------------------------------------
resource "aws_security_group" "runner" {
  name_prefix = "${var.name_prefix}-runner-"
  description = "Ephemeral GHA runners - no inbound, egress to VPC only"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to VPC endpoints + in-VPC GitHub Enterprise Server"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # NO 0.0.0.0/0 -> no internet egress
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "lambda" {
  name_prefix = "${var.name_prefix}-lambda-"
  description = "Control-plane Lambdas in-VPC - egress to VPC only"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to VPC endpoints + GHES"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name_prefix}-vpce-"
  description = "VPC interface endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from inside the VPC (runners, lambdas, GHES)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  lifecycle { create_before_destroy = true }
}

# --- Account-scoped endpoint policy ------------------------------------------
# Allow only principals from THIS account to use the endpoints. Combined with
# private subnets this means "specific account, no public" for all AWS access.
data "aws_iam_policy_document" "endpoint_account_only" {
  statement {
    sid       = "ThisAccountOnly"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# --- Interface endpoints (PrivateLink) ---------------------------------------
locals {
  interface_endpoints = [
    "ecr.api",        # ECR control plane
    "ecr.dkr",        # ECR image push/pull
    "logs",           # CloudWatch Logs
    "secretsmanager", # GitHub App key + webhook secret
    "sts",            # caller identity / token
    "ssm",
    "kms",            # cosign signing + secret/ECR decrypt
    "sqs",            # in-VPC Lambdas <-> queue
    "ecs",            # RunTask
    "ecs-agent",
    "ecs-telemetry",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  policy              = data.aws_iam_policy_document.endpoint_account_only.json
}

# execute-api endpoint: the ONLY way to reach the private webhook REST API.
resource "aws_vpc_endpoint" "execute_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}

# S3 gateway endpoint: ECR layers live in S3; pulls need this. Scoped to account.
data "aws_route_tables" "private" {
  vpc_id = var.vpc_id
  filter {
    name   = "association.subnet-id"
    values = var.private_subnet_ids
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.private.ids
  policy            = data.aws_iam_policy_document.endpoint_account_only.json
}
