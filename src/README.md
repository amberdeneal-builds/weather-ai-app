# src/

- `handler.py` — the Lambda function's entry point. Given `lat`/`lon` query
  parameters (and an optional `city` label for display), it:
  1. Checks DynamoDB for a fresh cached result (`CACHE_TTL_SECONDS`).
  2. On a cache miss, fetches current conditions + today's forecast from the
     National Weather Service (`api.weather.gov` — free, no API key).
  3. Asks Bedrock (Claude Haiku 4.5, via the `us.` cross-Region inference
     profile) for a short, human-readable insight based on those conditions.
     **If Bedrock fails for any reason, the same prompt is sent to GCP Vertex
     AI (Gemini 2.5 Flash) instead** — see below.
  4. Caches the combined result and returns it as JSON.

  Not VPC-attached — DynamoDB, Bedrock, and Secrets Manager are all regional
  AWS APIs reachable via IAM alone, and this function also needs the public
  internet (NWS and `*.googleapis.com`), which the private-subnet VPC in
  `terraform/vpc.tf` deliberately has no route to. See the comment at the top
  of `terraform/lambda.tf` for the full reasoning.

- `requirements.txt` — `google-auth` and `requests`, both pure-Python with no
  compiled extensions, so a `pip install` on macOS produces a package that runs
  unchanged on Lambda's Linux runtime. `terraform/lambda.tf` vendors these into
  the deployment zip via a `terraform_data` + `local-exec` build step, keyed on
  a hash of this file and `handler.py` so it only rebuilds when either changes.

## The Bedrock → Vertex AI failover

`get_ai_insight()` calls Bedrock first. On any `ClientError` it logs the reason
and falls through to `_invoke_vertex()`, which:

1. Reads the GCP service-account key from Secrets Manager (cached at module
   scope, so a warm container doesn't re-fetch it).
2. Mints a short-lived OAuth2 access token via `google.oauth2.service_account`,
   refreshing only when the cached token has actually expired.
3. POSTs to Vertex AI's `generateContent` REST endpoint with `urllib.request`.

There's no `google-cloud-aiplatform` SDK dependency — the REST call is a few
lines and the SDK would pull in substantially more than the two pure-Python
packages above.

If Vertex AI *also* fails, both the original Bedrock error and the Vertex error
are included in the raised `UpstreamError`, so a genuine dual-provider outage is
never silently reduced to a single misleading message.

Each path logs which provider served the request (`ai_insight served by:
bedrock` / `ai_insight served by: vertex (bedrock failover)`), which is what
makes the failover verifiable in CloudWatch rather than merely plausible.

**Known gap:** authentication to Vertex AI currently uses a long-lived
service-account key. Migrating to Workload Identity Federation — short-lived
tokens exchanged from the Lambda's own AWS identity, no stored credential — is
the next planned change here.

## A DynamoDB gotcha baked into this file

`boto3`'s DynamoDB *resource* layer refuses to serialize Python floats, and NWS
returns real floats (temperature, humidity, pressure). `_to_dynamodb_safe()`
converts them to `Decimal(str(value))` on the way in — the `str()` round-trip
avoids binary float imprecision — and `_from_dynamodb_safe()` converts back to
`int`/`float` on a cache hit, so the JSON response contains real numbers rather
than strings.
