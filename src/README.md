# src/

- `handler.py` — the Lambda function's entry point. Given `lat`/`lon` query
  parameters (and an optional `city` label for display), it:
  1. Checks DynamoDB for a fresh cached result (`CACHE_TTL_SECONDS`).
  2. On a cache miss, fetches current conditions + today's forecast from the
     National Weather Service (`api.weather.gov` — free, no API key).
  3. Asks Bedrock (Claude 3.5 Haiku) for a short, human-readable insight
     based on those conditions.
  4. Caches the combined result and returns it as JSON.

  Not VPC-attached — DynamoDB, Bedrock, and Secrets Manager are all regional
  AWS APIs reachable via IAM alone, and this function also needs the public
  internet (NWS), which the private-subnet VPC in `terraform/vpc.tf`
  deliberately has no route to. See the comment at the top of
  `terraform/lambda.tf` for the full reasoning.

  Not yet implemented: GCP Vertex AI failover if Bedrock is unavailable —
  `get_ai_insight()` is the seam where that retry will go once the Secrets
  Manager entry for the Vertex credential exists (see
  `weather-ai-app-account-structure.md`, "Next steps").
