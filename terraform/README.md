# terraform/ — Weather AI infrastructure

Everything AWS-side for Weather AI: the account structure (IAM, VPC, KMS), the
data and compute layer (DynamoDB, Secrets Manager, Lambda), the public API
(API Gateway HTTP API + custom domain), and cost guardrails.

DNS is *not* here — `amberdeneal.dev` lives entirely on Cloudflare (see the root
README for why). Terraform reads the existing ACM certificate as a data source
but manages no DNS records.

## What this creates

| File | Resources | Purpose |
|---|---|---|
| `iam.tf` | `aws_iam_role.lambda_exec` + inline policy | Least-privilege Lambda execution role |
| `vpc.tf` | VPC, 2 private subnets, route table, VPC endpoints, 2 security groups, 1 NACL | Network layer — **no longer what the Lambda runs in**, see below |
| `kms.tf` | `aws_kms_key.secrets` + alias + key policy | CMK for Secrets Manager, rotation enabled |
| `dynamodb.tf` | `aws_dynamodb_table.cache` | On-demand cache table with TTL |
| `secrets.tf` | Secrets Manager secret + version | Holds the GCP service-account key for the Vertex AI failover |
| `lambda.tf` | `aws_lambda_function.api`, log group, `terraform_data` build step | The function itself, plus the vendored-dependency packaging |
| `apigateway.tf` | HTTP API, integration, route, `$default` stage, Lambda permission, custom domain, API mapping | The public API — imported, not created (see below) |
| `budgets.tf` | `aws_budgets_budget.monthly_cost` | Account-wide spend alerts, actual + forecasted |
| `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf` | — | Provider config, inputs, tags, outputs |

## Design notes

**IAM role.** Every statement is scoped to a specific resource ARN — the
function's own log group, the cache table, the Bedrock inference profile and its
underlying foundation models, secrets under a project-specific name prefix —
rather than `*`. `kms:Decrypt`/`DescribeKey` is the one broad statement, and the
real restriction lives on the other side of that relationship: the KMS key's own
policy in `kms.tf` names this role specifically.

Bedrock needs **two** statements rather than one, because Claude Haiku 4.5 is
reachable in `us-east-1` only through a cross-Region inference profile. AWS
authorizes against both the profile ARN the caller names and the foundation-model
ARN in whichever region the profile routes to, so `InvokeViaInferenceProfileOnly`
grants the profile and `InvokePrimaryModelViaProfileOnly` grants the model across
all four destination regions — scoped by a `bedrock:InferenceProfileArn`
condition, so the model can't be invoked directly and bypass the profile.

**VPC — deployed, correct, and not in the request path.** Private-subnet-only, no
NAT gateway, no internet gateway, AWS services reached through VPC endpoints. The
Lambda ran here originally, and the design is sound for a function that only talks
to AWS. It stopped being right the moment the function needed `api.weather.gov`,
which is a third-party service on the public internet that VPC endpoints cannot
reach. Rather than add a NAT gateway (~$32/mo for a portfolio app), the Lambda
dropped its VPC attachment entirely — the standard pattern when nothing being
called lives inside a VPC. This module still builds the VPC because it's a real,
working artifact of the networking work; it just isn't load-bearing anymore.

One lesson preserved in `vpc.tf`'s comments: NACLs can't reference prefix lists,
only literal CIDRs. Because DynamoDB gateway-endpoint traffic uses DynamoDB's own
service IP ranges rather than anything inside the VPC CIDR, NACL rules scoped to
`var.vpc_cidr` silently dropped every packet — which presented as a Lambda that
timed out at exactly 10s, every time. Two rules are widened to `0.0.0.0/0` as a
documented tradeoff, since the security groups do the real access control.

**KMS.** One customer-managed key, rotation enabled. The policy grants account
root full administrative access (the standard guardrail against locking every
principal out) and grants the Lambda role decrypt-only rights. Note that
`AWSKeyManagementServicePowerUser` deliberately omits `kms:PutKeyPolicy`, so the
key policy also names the calling principal explicitly — without that,
`CreateKey` fails validation.

**API Gateway was imported, not created.** These resources were built by hand in
the console before Terraform covered them. `terraform import` brought the real
ones under management rather than creating duplicates — creating them fresh would
have meant destroying and recreating a live custom domain for no reason. Two
details make the import clean: `aws_lambda_permission.apigw` pins the
console-generated statement ID UUID (that attribute forces replacement, and a
replacement would briefly break invocation), and the `$default` stage import ID
needs single quotes in zsh or `$default` expands to an empty string.

**Budgets.** `budgets.tf` carries the account's real measured cost breakdown in
its comments, including the reason a `RECORD_TYPE=Usage` filter is required to
see anything but `$0.00` on a credit-covered account.

## Cost

Both interface-endpoint toggles (`enable_interface_endpoints`,
`enable_lambda_logs_endpoint`) default to off and should stay off — an off-VPC
Lambda reaches CloudWatch Logs and every other AWS API directly and for free, so
those endpoints would be pure waste. When on, they run ~$0.01/hr each.

Everything else here is effectively free at this scale: the VPC, subnets, security
groups, NACL, IAM role, DynamoDB gateway endpoint, on-demand DynamoDB, and the
Lambda itself. The KMS key and the Secrets Manager secret carry small fixed
monthly charges. Measured August run-rate for the whole account, before free-tier
credits, was ~$4 — and most of that was an unrelated EC2 instance.

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform plan
terraform apply
```

Two variables have **no default** and must be set in `terraform.tfvars`, which is
gitignored:

- `gcp_vertex_key_path` — path to the GCP service-account JSON key on the machine
  running Terraform. The file lives outside the repo entirely; Terraform reads its
  contents into Secrets Manager via `sensitive(file(pathexpand(...)))`, so the key
  never appears in plan output or git history.
- `budget_alert_email` — where AWS Budgets sends threshold alerts. Kept out of the
  repo because this repo is public and committed email addresses get scraped.

No backend is configured — state is local (`terraform.tfstate`, gitignored).
Before this manages anything you'd be upset to lose, add an S3 + DynamoDB backend
(see the commented block in `versions.tf`), provisioned outside this module so
state isn't managing its own storage.

## Not yet in this module

- **Workload Identity Federation.** The Vertex AI failover authenticates with a
  long-lived service-account key held in Secrets Manager. Replacing it with
  federated short-lived tokens — and deleting the key — is the next planned change.
- S3 + CloudFront for the static front-end
- A CI/CD pipeline (GitHub Actions: `pytest`, lint, `terraform plan` on push)
- A remote Terraform backend
- Separate dev/prod workspaces — there's currently one environment

## A note on `../iam/`

`terraform-deployer` — the IAM user that runs `terraform apply` — has its own
policies managed by CLI rather than by this module, with the documents checked in
under `../iam/` for reference. That's the bootstrapping problem: an identity can't
safely manage its own permissions through the same apply that uses them without
risking locking itself out mid-run. See `../iam/README.md`.
