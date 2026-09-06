# Cost tripwire for this AWS account's spend.
#
# Cost control here had been architectural up to now - the
# enable_interface_endpoints/enable_lambda_logs_endpoint toggles exist so
# interface VPC endpoints can be switched off (both are currently off),
# DynamoDB is on-demand rather than provisioned, and the Lambda log group
# has an explicit 14-day retention so it can't become an unbounded cost
# leak. That's good design, but none of it *tells* anyone when something
# starts running away. This budget is that missing signal.
#
# Real numbers, from `aws ce get-cost-and-usage` for August 2026 filtered
# to RECORD_TYPE=Usage (i.e. what the resources cost before free-tier
# credits are applied - net of credits the account currently bills $0):
#
#   Amazon EC2 - Compute      $2.54   <- NOT this project (see below)
#   Amazon VPC                $1.24   <- the CloudWatch Logs interface
#                                        endpoint, running until it was
#                                        turned off on Sept 6, 2026
#   EC2 - Other               $0.21   <- EBS volume of that same instance
#   KMS                       $0.003
#   Secrets Manager           $0.000005
#   Lambda / DynamoDB / API Gateway / CloudWatch   $0
#   ---------------------------------------------
#   Total                     ~$3.99
#
# Two things worth knowing from that breakdown. First, this project's own
# footprint is genuinely tiny - pennies per month; an earlier guess that
# the KMS CMK (~$1/mo) and Secrets Manager secret (~$0.40/mo) would
# dominate was simply wrong, they're rounding errors here. Second, the two
# largest line items weren't this project at all: the EC2 compute and its
# EBS volume are a t3.micro test instance from an unrelated Solutions
# Architect course (i-07c1aab6ea5aa89e2, us-east-1, stopped since late
# August), and the VPC charge was the Logs interface endpoint that is now
# switched off. A budget is account-wide, so it watches all of that, not
# just what this Terraform config manages.
#
# The $10 default ceiling is therefore generous headroom over a real
# run-rate of a few dollars - crossing even the 50% threshold would mean
# something genuinely changed. Note also that AWS's *forecast* on a
# near-zero-spend account is unreliable: it was projecting $12.57 for a
# month whose actual net spend was $0.00, which is why the thresholds here
# are anchored to a real reviewed number rather than to whatever AWS
# happens to be forecasting.
#
# The GCP side has an equivalent $5/month budget on the weather-ai-507817
# project, created via `gcloud billing budgets create` rather than
# Terraform - there's no Google provider configured in this project, and
# adding one just for a budget wasn't worth it. Worth knowing the two
# clouds' guardrails are managed differently.

resource "aws_budgets_budget" "monthly_cost" {
  name         = "${local.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Actual spend crossing 50% / 80% / 100% of the ceiling.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # Forecasted spend crossing 100%. This is the one that catches a runaway
  # early: AWS projects the month's total from spend so far, so a cost
  # spike on the 3rd trips this days before actual spend would reach the
  # ceiling. ACTUAL thresholds alone would only warn once the money is
  # already gone.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
