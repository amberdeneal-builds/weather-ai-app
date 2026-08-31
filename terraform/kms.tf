# Customer-managed key for secrets: Secrets Manager entries (e.g. the GCP
# Vertex AI failover credential) and Lambda environment variable encryption.
# A CMK (vs. the AWS-managed aws/secretsmanager key) is what lets the key
# policy below scope decrypt rights to exactly the Lambda role, instead of
# "any principal with secretsmanager:GetSecretValue in this account".

data "aws_iam_policy_document" "kms_secrets_key_policy" {
  # Account root always keeps administrative access to its own keys - this
  # is the standard AWS guardrail against a misconfigured policy locking
  # everyone (including account admins) out of the key.
  statement {
    sid    = "EnableAccountRootFullAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # AWS validates, at CreateKey time, that the caller making the request
  # will still be able to manage the key's policy afterwards - and it does
  # NOT credit the root statement above toward that check for an IAM user
  # or role, only for the literal root principal. Usage-focused managed
  # policies (like AWSKeyManagementServicePowerUser) deliberately omit
  # kms:PutKeyPolicy, since using a key and administering one are meant to
  # be separate privileges. Without this statement naming the caller
  # directly, CreateKey fails with MalformedPolicyDocumentException ("The
  # new key policy will not allow you to update the key policy in the
  # future") even though the root statement is present and correct.
  statement {
    sid    = "AllowCurrentCallerKeyAdministration"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.arn]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # The Lambda execution role may only use the key for decryption - it never
  # needs kms:Encrypt, kms:CreateKey, kms:PutKeyPolicy, etc. Application code
  # reads secrets; it doesn't write them.
  statement {
    sid    = "AllowLambdaRoleDecrypt"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.lambda_exec.arn]
    }
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key" "secrets" {
  description             = "CMK for ${local.name_prefix} secrets (Secrets Manager entries, Lambda env vars)"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_secrets_key_policy.json

  tags = {
    Name = "${local.name_prefix}-secrets"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}