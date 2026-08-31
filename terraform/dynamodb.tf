# Cache table for weather lookups. On-demand billing (PAY_PER_REQUEST) - a
# demo/portfolio app with unpredictable, low request volume shouldn't pay
# for provisioned capacity it isn't using. Same cost-guardrail thinking as
# skipping the NAT Gateway in vpc.tf, applied to DynamoDB instead of EC2/VPC.

resource "aws_dynamodb_table" "cache" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cache_key"

  attribute {
    name = "cache_key"
    type = "S"
  }

  # Cache entries expire on their own - DynamoDB deletes items past their
  # expires_at time in the background, at no extra cost, so stale weather
  # data never has to be cleaned up manually.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Name = "${local.name_prefix}-cache"
  }
}
