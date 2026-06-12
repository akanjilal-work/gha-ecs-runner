# In-account image signing key (cosign). Asymmetric ECC key: the private half
# never leaves KMS; the runner signs with kms:Sign, anyone in the account can
# verify with the public half. No public Sigstore is ever involved.

resource "aws_kms_key" "signing" {
  description              = "${local.prefix} cosign image signing key"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootAccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Any principal in this account may verify and read the public key, so
        # the deploy-time signature gate is trivial to run anywhere in-account.
        Sid       = "AccountWideVerify"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = ["kms:GetPublicKey", "kms:Verify", "kms:DescribeKey"]
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "signing" {
  name          = "alias/${local.prefix}-signing"
  target_key_id = aws_kms_key.signing.key_id
}
