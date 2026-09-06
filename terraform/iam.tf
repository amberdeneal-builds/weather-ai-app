# Least-privilege execution role for the Weather AI Lambda function.
#
# Every statement below is scoped to a specific resource ARN rather than "*",
# with one exception that AWS itself requires to be broad: kms:Decrypt/
# DescribeKey, where "*" here is safe because the *key's own policy*
# (kms.tf) is what actually restricts usage to this role - the account only
# has this one CMK the role is meant to touch.
#
# No VPC ENI permissions here: the function isn't VPC-attached (see the
# comment at the top of lambda.tf), so it never needs ec2:CreateNetworkInterface
# and friends.

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

  # Bedrock — invoke exactly one model, nothing account-wide (no bedrock:*,
  # no access to other models, no fine-tuning/agent APIs). This needs two
  # statements because bedrock_model_id is a cross-Region inference profile,
  # not a bare foundation model (Claude Haiku 4.5 isn't offered for direct
  # in-region invocation in us-east-1 - only through a Geo/Global profile).
  # AWS checks IAM permission on *both* the profile ARN the caller names
  # and the foundation-model ARN in whichever region the profile actually
  # routes the request to, so both need a statement - see the AWS ML blog
  # "Securing Amazon Bedrock cross-Region inference" for the pattern this
  # follows.
  statement {
    sid    = "InvokeViaInferenceProfileOnly"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}",
    ]
  }

  statement {
    sid    = "InvokePrimaryModelViaProfileOnly"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      for region in var.bedrock_profile_destination_regions :
      "arn:${data.aws_partition.current.partition}:bedrock:${region}::foundation-model/${var.bedrock_foundation_model_id}"
    ]

    # Without this, the role could invoke the foundation model directly in
    # any of those regions, bypassing the profile entirely - this pins that
    # grant to only fire as part of a call through our one named profile.
    condition {
      test     = "StringEquals"
      variable = "bedrock:InferenceProfileArn"
      values = [
        "arn:${data.aws_partition.current.partition}:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}",
      ]
    }
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
}

resource "aws_iam_role_policy" "lambda_exec" {
  name   = "${local.name_prefix}-lambda-exec-policy"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec_policy.json
}
