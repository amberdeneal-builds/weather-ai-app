output "lambda_execution_role_arn" {
  description = "ARN of the least-privilege IAM role Lambda assumes."
  value       = aws_iam_role.lambda_exec.arn
}

output "lambda_execution_role_name" {
  value = aws_iam_role.lambda_exec.name
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Subnets the Lambda function should be deployed into."
  value       = aws_subnet.private[*].id
}

output "lambda_security_group_id" {
  description = "Attach this to the Lambda function's VPC config."
  value       = aws_security_group.lambda.id
}

output "vpc_endpoints_security_group_id" {
  value = aws_security_group.vpc_endpoints.id
}

output "kms_secrets_key_arn" {
  description = "CMK for encrypting Secrets Manager secrets and Lambda environment variables."
  value       = aws_kms_key.secrets.arn
}

output "kms_secrets_key_alias" {
  value = aws_kms_alias.secrets.name
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.cache.name
}

output "dynamodb_table_arn" {
  value = aws_dynamodb_table.cache.arn
}

output "lambda_function_name" {
  description = "Pass this to `aws lambda invoke --function-name`."
  value       = aws_lambda_function.api.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.api.arn
}

output "lambda_log_group_name" {
  description = "Empty of log data unless enable_interface_endpoints or enable_lambda_logs_endpoint is true."
  value       = aws_cloudwatch_log_group.lambda.name
}
