# src/

- `handler.py` — the Lambda function's entry point. Right now it's
  deliberately minimal: it writes one item to the DynamoDB cache table and
  reads it back, to prove the IAM role, VPC networking, and DynamoDB table
  built in `terraform/` actually work together end to end.
- Real weather-fetching + Bedrock AI-insight logic isn't here yet — that's
  a later step once this plumbing is confirmed working.
