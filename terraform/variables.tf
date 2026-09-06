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
  description = "Bedrock model ID the Lambda invokes. This is a US geographic cross-Region inference profile ID (e.g. \"us.<model>\"), not a bare foundation-model ID - Claude Haiku 4.5 (the successor to Claude 3.5 Haiku, which hit its June 19, 2026 end-of-life) isn't offered for direct in-region invocation in us-east-1, only through a Geo or Global inference profile. Passed straight through to boto3's invoke_model(modelId=...) - profile IDs work exactly like model IDs there."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "bedrock_foundation_model_id" {
  description = "The underlying foundation-model ID behind bedrock_model_id's inference profile (same string with the geo prefix, e.g. \"us.\", stripped off). Needed separately because IAM permission for a cross-Region inference profile requires granting the profile ARN *and* the foundation-model ARN in every region the profile can route to (see bedrock_profile_destination_regions) - AWS checks both."
  type        = string
  default     = "anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "bedrock_profile_destination_regions" {
  description = "Every AWS region bedrock_model_id's inference profile is allowed to route a request to. For the \"us.\" geographic profile this is the US region set Anthropic/AWS publish on the model's Bedrock model card - currently us-east-1, us-east-2, us-west-1, and us-west-2. Must stay in sync with whichever profile bedrock_model_id points at, or InvokeModel calls will fail with an IAM error whenever Bedrock happens to route to a region not in this list."
  type        = list(string)
  default     = ["us-east-1", "us-east-2", "us-west-1", "us-west-2"]
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

variable "cache_ttl_seconds" {
  description = "How long a cached weather+insight response stays fresh in DynamoDB before the next request re-fetches from NWS/Bedrock."
  type        = number
  default     = 600
}

variable "nws_user_agent" {
  description = "User-Agent header sent to api.weather.gov. NWS asks for a descriptive value identifying the app, ideally with a way to reach the maintainer - no API key is required, but requests without a reasonable User-Agent can be rate-limited more aggressively."
  type        = string
  default     = "weather-ai-app (https://github.com/amberdeneal-builds/weather-ai-app)"
}

variable "gcp_project_id" {
  description = "GCP project ID that owns the Vertex AI failover service account. Informational (used only in a resource description) - not passed to any AWS or Google API call from Terraform itself."
  type        = string
  default     = "weather-ai-507817"
}

variable "gcp_vertex_key_path" {
  description = "Local filesystem path to the GCP service account JSON key (weather-ai-vertex-failover) used for Vertex AI failover. Never committed - lives outside the repo entirely and is only referenced from the gitignored terraform.tfvars. Supports \"~\" (expanded via pathexpand()). Required - no default, since every machine that runs terraform apply needs its own copy of the key file at whatever path it actually lives at there."
  type        = string
}

variable "gcp_vertex_location" {
  description = "GCP region for Vertex AI failover calls (the Gemini model must be available there). us-central1 is the most broadly available Vertex AI region for Gemini models."
  type        = string
  default     = "us-central1"
}

variable "gcp_vertex_model_id" {
  description = "Gemini model ID invoked on Vertex AI as the Bedrock failover. Google's Gemini model lineup moves fast (see the Bedrock Claude 3.5 Haiku EOL gotcha from Sept 6, 2026 for what happens when a model ID goes stale) - if Vertex calls start failing with a not-found-style error, check docs.cloud.google.com/vertex-ai/generative-ai/docs/learn/model-versions for the current model ID and bump this."
  type        = string
  default     = "gemini-2.5-flash"
}

variable "http_api_name" {
  description = "Name of the API Gateway HTTP API. Matches the name already assigned when it was created by hand in the console (Sept 2, 2026) - kept as its own variable rather than reusing lambda_function_name so the two aren't accidentally coupled just because they happen to share a value today."
  type        = string
  default     = "weather-ai-api"
}

variable "api_custom_domain_name" {
  description = "Custom domain the HTTP API is mapped to. DNS for this domain lives in Cloudflare, not Route 53 (see the project doc) - Terraform only reads the existing ACM certificate for it and wires up the AWS-side domain name + mapping."
  type        = string
  default     = "api.amberdeneal.dev"
}

variable "monthly_budget_usd" {
  description = "Monthly AWS spend ceiling (USD) that the budget alert thresholds are measured against. Set well above the account's reviewed run-rate (~$4/month uncredited as of August 2026, and most of that was an unrelated course EC2 instance plus an interface endpoint that has since been turned off - see the cost breakdown in budgets.tf), so crossing a threshold means something actually changed rather than normal variation. This is an account-wide budget, not scoped to this project's resources."
  type        = number
  default     = 10
}

variable "budget_alert_email" {
  description = "Email address AWS Budgets sends threshold alerts to. Required, with no default, and set only in the gitignored terraform.tfvars - this repo is public, and a personal email address committed to a public repo is a standing invitation for scraping. Same reasoning as gcp_vertex_key_path: the value is personal to whoever runs this, so it doesn't belong in version control."
  type        = string
}
