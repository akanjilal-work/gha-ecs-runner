# Customer-managed KMS key used to encrypt: secrets, ECR images, log groups,
# SQS, and Fargate ephemeral storage. Single key here for clarity; split per
# data domain in higher-security environments.
resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 14
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

# Asymmetric CMK used by cosign to SIGN container images in-account. No public
# Sigstore/Fulcio/Rekor dependency: cosign signs with this key and we disable
# the transparency log (--tlog-upload=false), so signing only touches KMS + ECR,
# both reachable over PrivateLink. Asymmetric keys cannot auto-rotate; rotate
# manually by issuing a new key + signing profile when required.
resource "aws_kms_key" "signing" {
  description              = "${var.name_prefix} cosign image-signing key"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 14
}

resource "aws_kms_alias" "signing" {
  name          = "alias/${var.name_prefix}-signing"
  target_key_id = aws_kms_key.signing.key_id
}

# Allow CloudWatch Logs + ECR + SQS services to use the key.
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "RootAccount"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowAwsServices"
    effect = "Allow"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"
    ]
    resources = ["*"]
    principals {
      type = "Service"
      identifiers = [
        "logs.${var.region}.amazonaws.com",
        "sqs.amazonaws.com",
      ]
    }
  }
}

resource "aws_kms_key_policy" "main" {
  key_id = aws_kms_key.main.id
  policy = data.aws_iam_policy_document.kms.json
}

# --- GitHub App private key (PEM) -------------------------------------------
resource "aws_secretsmanager_secret" "app_key" {
  name       = "${var.name_prefix}/github-app-private-key"
  kms_key_id = aws_kms_key.main.arn
}
# Value is set out-of-band (CLI / CI) so the PEM never lands in state:
#   aws secretsmanager put-secret-value --secret-id <arn> --secret-string file://app.pem

# --- Webhook HMAC secret -----------------------------------------------------
resource "aws_secretsmanager_secret" "webhook" {
  name       = "${var.name_prefix}/webhook-secret"
  kms_key_id = aws_kms_key.main.arn
}

resource "random_password" "webhook" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret_version" "webhook" {
  secret_id     = aws_secretsmanager_secret.webhook.id
  secret_string = random_password.webhook.result
}
