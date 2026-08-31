# Least-privilege execution role for the Weather AI Lambda function.
#
# Every statement below is scoped to a specific resource ARN rather than "*",
# with two exceptions that AWS itself requires to be broad:
#   - the ENI lifecycle actions needed to run Lambda inside a VPC at all
#   - kms:Decrypt/DescribeKey, where "*" here is safe because the *key's own
#     policy* (kms.tf) is what actually restricts usage to this role — the
#     account only has this one CMK the role is meant to touch.

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    # Defense-in-depth against the "confused deputy" case: only let
    # lambda.amazonaws.com assume this role on behalf of *this* account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.name_prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "${local.name_prefix}-lambda-exec"
  }
}

data "aws_iam_policy_document" "lambda_exec_policy" {
  # CloudWatch Logs — scoped to this function's exact log group, not
  # "/aws/lambda/*". The log group doesn't exist yet (Lambda creates it on
  # first invoke), so this is a forward reference to its known future ARN.
  statement {
    sid    = "WriteOwnLogGroupOnly"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.lambda_function_name}:*",
    ]
  }

  # DynamoDB cache table — read/write the item-level APIs the API layer
  # needs; no table-management actions (CreateTable, DeleteTable, PutItem
  # ok, but no UpdateTable/DeleteTable). Table + one GSI, both forward
  # references like the log group above.
  statement {
    sid    = "CacheTableReadWrite"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}",
      "arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}/index/*",
    ]
  }

  # Bedrock — invoke exactly one foundation model, nothing account-wide
  # (no bedrock:*, no access to other models, no fine-tuning/agent APIs).
  statement {
    sid    = "InvokePrimaryModelOnly"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:bedrock:${var.aws_region}::foundation-model/${var.bedrock_model_id}",
    ]
  }

  # Secrets Manager — read-only, and only secrets under this project's
  # name prefix (e.g. weather-ai/gcp-vertex-failover-key).
  statement {
    sid    = "ReadOwnSecretsOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_name_prefix}*",
    ]
  }

  # KMS — decrypt only. Scoped for real by the key policy in kms.tf, which
  # names this exact role; "*" here just means "whichever key(s) grant me
  # access", and today that's the one CMK this module creates.
  statement {
    sid    = "DecryptWithProjectKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # ENI lifecycle — required for any Lambda function attached to a VPC.
  # AWS does not support resource-level restriction on these four actions,
  # so this is the one intentionally broad statement in this policy.
  statement {
    sid    = "VpcEniLifecycle"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_exec" {
  name   = "${local.name_prefix}-lambda-exec-policy"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec_policy.json
}
