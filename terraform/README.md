# terraform/ — Weather AI account structure

This module provisions the AWS account structure Weather AI's Lambda/API
layer runs in: nothing here deploys application code. It's the Weeks 1–4
(AWS SAA-C03) hands-on lab deliverable — IAM, VPC, and KMS, built before any
Lambda function or DynamoDB table exists.

## What this creates

| File | Resources | Purpose |
|---|---|---|
| `iam.tf` | `aws_iam_role.lambda_exec` + inline policy | Least-privilege Lambda execution role |
| `vpc.tf` | VPC, 2 private subnets, route table, VPC endpoints, 2 security groups, 1 NACL | Network for the API layer, no public ingress/egress |
| `kms.tf` | `aws_kms_key.secrets` + alias + key policy | CMK for Secrets Manager entries and Lambda env var encryption |
| `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf` | — | Provider config, inputs, tags, outputs |

## Design notes

**IAM role.** Every statement is scoped to a specific resource ARN — the
function's own log group, the cache table (+ its indexes), one named
Bedrock model, secrets under a project-specific name prefix — rather than
`*`. The two exceptions (`kms:Decrypt`/`DescribeKey` and the EC2 ENI
lifecycle actions) are broad because AWS either doesn't support finer
scoping (ENI actions) or because the real restriction lives on the other
side of the relationship (the KMS key's own policy in `kms.tf` names this
role specifically, so a `*` resource on the IAM side doesn't actually widen
access). The DynamoDB table and Bedrock model referenced don't exist yet at
this stage of the build — the ARNs are forward references to what the
Week 1–4 Lambda+DynamoDB step will create under these same names.

**VPC.** Private-subnet-only, no NAT Gateway, no internet gateway. Every AWS
service the Lambda role can call (DynamoDB, KMS, Secrets Manager, CloudWatch
Logs, Bedrock Runtime) is reached through a VPC endpoint instead, so there's
no route to `0.0.0.0/0` from these subnets at all — the "least privilege"
brief applies to the network, not just IAM. Security groups do the real
enforcement (Lambda SG: HTTPS egress to endpoints only, no ingress; endpoint
SG: HTTPS ingress from the Lambda SG only); the NACL is a stateless,
subnet-level backstop that permits HTTPS + ephemeral-port return traffic
within the VPC CIDR and nothing else.

**KMS.** One customer-managed key for secrets, rotation enabled. Its policy
grants the account root full administrative access (the standard AWS
guardrail against a policy locking out every principal, including admins)
and grants the Lambda role decrypt-only rights — no `Encrypt`, no
`PutKeyPolicy`. Application code should never need to write ciphertext with
this key, only read it.

## Cost

With `enable_interface_endpoints = true` (the default), the four interface
endpoints run ~$0.01/hr each (~$29/mo combined) plus data processing — the
DynamoDB gateway endpoint, the VPC, subnets, security groups, NACL, IAM
role, and KMS key itself are free. Set `enable_interface_endpoints = false`
in `terraform.tfvars` to validate the network topology at $0 while the
Lambda function doesn't exist yet to use the endpoints anyway.

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit as needed
terraform init
terraform plan
terraform apply
```

No backend is configured — state is local (`terraform.tfstate`, gitignored).
Before this manages anything you'd be upset to lose, add an S3 + DynamoDB
backend (see the commented block in `versions.tf`) provisioned outside this
module, so state isn't managing its own storage.

## Not yet in this module

- The DynamoDB cache table and the Lambda function itself (next: Weeks 1–4
  "Lambda + DynamoDB" step)
- The Secrets Manager secret(s) the KMS key encrypts — created when the GCP
  Vertex AI failover credential is wired up (Week 8, Workload Identity
  Federation)
- API Gateway
- A remote Terraform backend
