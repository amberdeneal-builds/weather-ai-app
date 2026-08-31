variable "project_name" {
  description = "Short project identifier used in resource names and tags."
  type        = string
  default     = "weather-ai"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Keeps a single account usable for more than one stage via distinct name prefixes."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region for all resources. Bedrock's Claude 3.5 Haiku and the chosen VPC interface endpoints must both be available here."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the Weather AI VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread the private subnets across. Two is enough for Lambda's HA requirements without paying for a third NAT-less endpoint set."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for the private (Lambda-eligible) subnets, one per AZ in availability_zones."
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "enable_interface_endpoints" {
  description = "Whether to create the interface VPC endpoints (KMS, Secrets Manager, CloudWatch Logs, Bedrock Runtime). Each interface endpoint has an hourly + per-GB cost; the DynamoDB gateway endpoint is always created since it's free. Turn this off for a pure cost-zero dry run of the network layer."
  type        = bool
  default     = true
}

variable "enable_lambda_logs_endpoint" {
  description = "Create just the CloudWatch Logs interface VPC endpoint, independent of enable_interface_endpoints. A VPC-attached Lambda function has no route to CloudWatch Logs without either this endpoint or a NAT Gateway, so its own execution logs won't be visible without one of the two. ~$0.01/hr (~$7/mo) alone - much cheaper than turning on all four interface endpoints just to get log visibility."
  type        = bool
  default     = false
}

variable "lambda_function_name" {
  description = "Name the Lambda function will be deployed under. Used to scope the IAM role's CloudWatch Logs permissions to its exact log group before the function exists."
  type        = string
  default     = "weather-ai-api"
}

variable "dynamodb_table_name" {
  description = "Name the DynamoDB cache table will be created under (in the Week 1-4 Lambda+DynamoDB step). Used to scope the IAM role's table permissions to its exact future ARN."
  type        = string
  default     = "weather-ai-cache"
}

variable "bedrock_model_id" {
  description = "Bedrock foundation model ID the Lambda role is allowed to invoke."
  type        = string
  default     = "anthropic.claude-3-5-haiku-20241022-v1:0"
}

variable "secrets_name_prefix" {
  description = "Name prefix for Secrets Manager secrets the Lambda role may read (e.g. the GCP Vertex AI failover credential). A prefix, not a fixed name, so multiple related secrets can share one IAM statement."
  type        = string
  default     = "weather-ai/"
}

variable "kms_key_deletion_window_days" {
  description = "Waiting period before a deleted KMS key is actually destroyed. AWS minimum/default is 30; keep it short in dev, longer in prod."
  type        = number
  default     = 7
}
