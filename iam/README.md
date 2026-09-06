# terraform-deployer IAM policies

These policy documents describe the permissions attached directly to the
`terraform-deployer` IAM user in the AWS account - the identity that runs
`terraform plan`/`apply` for this project from a human's terminal. They are
**not** applied by Terraform itself: this is the classic bootstrapping
problem - the identity running Terraform can't safely manage its own
permissions through the same Terraform run without risking locking itself
out mid-apply. They're managed directly via `aws iam create-policy` /
`attach-user-policy`, and kept here as documentation of what's actually
live in the account, not as executable infrastructure-as-code.

## Sept 6, 2026: consolidated from 9 AWS managed policies into 3 custom ones

Through Sept 2-6, 2026, `terraform-deployer` accumulated one AWS managed
policy per new service the project touched (VPC, IAM, KMS, DynamoDB,
CloudWatch Logs, Lambda, EC2 read-only, Bedrock, Secrets Manager, API
Gateway) - a reasonable incremental approach for a personal lab, but it hit
AWS's hard cap of 10 attached managed policies per user while codifying
API Gateway in Terraform. Rather than requesting an AWS quota increase, the
9 real policy documents were merged into 3 custom managed policies here,
preserving the exact same effective permissions (only genuinely redundant
duplicate grants were dropped - e.g. narrow `iam:PassRole` statements
scoped to specific services, when a blanket `iam:*` is already granted
elsewhere in the same policy set) while using far fewer of the 10 slots:

- `deployer-vpc-networking-policy.json` - the full EC2/VPC networking
  action list from `AmazonVPCFullAccess`, split into its own policy
  because it alone is close to AWS's 6144-character managed-policy size
  limit.
- `deployer-data-and-compute-policy.json` - KMS, DynamoDB (+ its bundled
  related-service actions), CloudWatch Logs/metrics, Lambda, and API
  Gateway.
- `deployer-iam-ai-secrets-policy.json` - IAM, Bedrock (+ its bundled
  SageMaker-marketplace and AWS Marketplace subscription actions, kept for
  fidelity even though this project doesn't currently use third-party
  Bedrock marketplace models), Secrets Manager, and the ACM read-only
  actions needed by `terraform/apigateway.tf`'s `aws_acm_certificate` data
  source (previously a separate inline user policy, now folded in here).

`AmazonEC2ReadOnlyAccess` was dropped entirely rather than merged in - it
was added transiently on Sept 2 for an `aws_ec2_managed_prefix_list` data
source lookup that was ultimately abandoned in favor of widening two NACL
rules to `0.0.0.0/0` (see the project doc). Nothing in the current
Terraform config uses it.

End state: 3 attached managed policies instead of 10, with 7 free slots
for whatever this project needs next - the actual problem this
consolidation solved, not just a tidiness exercise.

This was a **consolidation, not a least-privilege rewrite** - a
deliberate choice. `terraform-deployer` can still do everything it could
do before (a true least-privilege policy, scoped to the exact actions
each `.tf` file needs, is a bigger and separate exercise with real risk if
an action is missed mid-`apply`). It's still worth doing eventually,
tracked in the project's next-steps list.
