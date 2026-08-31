# Minimal Lambda: proves the IAM role (iam.tf), VPC networking (vpc.tf),
# and DynamoDB table (dynamodb.tf) actually work together end to end,
# before any real weather-fetching or Bedrock AI-insight logic is layered
# on top. See src/handler.py for what it actually does.

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/handler.py"
  output_path = "${path.module}/.build/lambda.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  # Created explicitly (rather than left for Lambda to create on first
  # invoke) so retention is bounded from day one - an unbounded log group
  # is a quiet, easy-to-forget cost leak. Note this only fills with data if
  # enable_interface_endpoints or enable_lambda_logs_endpoint is true - a
  # VPC-attached Lambda has no route to CloudWatch Logs without one of the
  # two (see the enable_lambda_logs_endpoint comment in variables.tf).
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
  timeout     = 10
  memory_size = 128

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.cache.name
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
