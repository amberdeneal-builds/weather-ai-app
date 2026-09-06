# Minimal-turned-real Lambda: proves the IAM role (iam.tf) and DynamoDB
# table (dynamodb.tf) work together, and now does the actual weather-fetch
# + Bedrock AI-insight work. See src/handler.py.
#
# Not VPC-attached. DynamoDB, Secrets Manager, KMS, and Bedrock are all
# regional AWS APIs reachable over their public endpoints via IAM alone -
# VPC attachment only matters for reaching resources that live *inside* a
# VPC (e.g. RDS in a private subnet), which this function never does. It
# also needs to reach the public internet (the NWS weather API), which the
# private-subnet-only VPC built in vpc.tf deliberately has no route to.
# That VPC/endpoint layer is kept as-is - a real, working lesson from Weeks
# 1-4 - it's just not what this function runs in.

# The deploy package now needs more than one file: handler.py plus the
# vendored google-auth/requests libraries the Vertex AI failover path needs
# (see src/requirements.txt - both are pure Python, no compiled/platform-
# specific extensions, so `pip install --target` produces the same files
# whether it's run on a Mac or Linux, and they work as-is on Lambda's Linux
# runtime with no cross-compilation step needed).
#
# archive_file only zips what's already on disk - it can't run pip itself -
# so terraform_data's local-exec provisioner builds .build/package first
# (wiping and reinstalling deps, then copying in the current handler.py),
# and archive_file depends_on that so it always zips a freshly-built
# directory. terraform_data is core Terraform (available since 1.4), not a
# separate provider - no new plugin to download for this.
resource "terraform_data" "lambda_deps" {
  triggers_replace = [
    filesha256("${path.module}/../src/handler.py"),
    filesha256("${path.module}/../src/requirements.txt"),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      rm -rf "${path.module}/.build/package"
      mkdir -p "${path.module}/.build/package"
      pip3 install --target "${path.module}/.build/package" -r "${path.module}/../src/requirements.txt"
      cp "${path.module}/../src/handler.py" "${path.module}/.build/package/handler.py"
    EOT
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/.build/package"
  output_path = "${path.module}/.build/lambda.zip"

  depends_on = [terraform_data.lambda_deps]
}

resource "aws_cloudwatch_log_group" "lambda" {
  # Created explicitly (rather than left for Lambda to create on first
  # invoke) so retention is bounded from day one - an unbounded log group
  # is a quiet, easy-to-forget cost leak.
  name              = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days = 14

  tags = {
    Name = "${local.name_prefix}-lambda-logs"
  }
}

resource "aws_lambda_function" "api" {
  function_name = var.lambda_function_name
  role          = aws_iam_role.lambda_exec.arn

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler     = "handler.lambda_handler"
  runtime     = "python3.13"
  timeout     = 30 # up from 10: up to 4 sequential NWS calls plus one Bedrock call
  memory_size = 128

  environment {
    variables = {
      TABLE_NAME             = aws_dynamodb_table.cache.name
      BEDROCK_MODEL_ID       = var.bedrock_model_id
      CACHE_TTL_SECONDS      = tostring(var.cache_ttl_seconds)
      NWS_USER_AGENT         = var.nws_user_agent
      GCP_PROJECT_ID         = var.gcp_project_id
      GCP_VERTEX_LOCATION    = var.gcp_vertex_location
      GCP_VERTEX_MODEL_ID    = var.gcp_vertex_model_id
      GCP_VERTEX_SECRET_NAME = aws_secretsmanager_secret.gcp_vertex_failover_key.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda_exec,
  ]

  tags = {
    Name = "${local.name_prefix}-api"
  }
}
