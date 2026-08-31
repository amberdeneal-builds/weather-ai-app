# Weather AI (Aeris)

> Status: 🚧 early build — AWS account structure only. No application code yet.

A Cloud Resume Challenge–style showcase app: serverless weather intelligence on AWS
with a GCP failover path, built as the public half of a two-project, multi-cloud
certification program (AWS SAA-C03 → GCP PCA/PDE/PMLE → AWS GenAI Dev Pro).

**Live prototype (dummy data, front-end only):** https://claude.ai/code/artifact/e45f8211-c509-499f-99ac-07f522351aa4

## Planned architecture

- **API layer:** Amazon API Gateway → AWS Lambda (Python), deployed into private
  VPC subnets, no public inbound path
- **Cache:** DynamoDB, reached through a VPC gateway endpoint
- **AI insight:** Amazon Bedrock (Claude 3.5 Haiku) as primary, with GCP Vertex AI
  (Gemini) as a failover path when Bedrock is unavailable
- **Secrets:** cross-cloud credentials (e.g. the Vertex AI failover key) held in
  Secrets Manager, encrypted with a customer-managed KMS key
- **Network egress:** locked down to VPC interface/gateway endpoints only — no NAT
  gateway, so egress is both least-privilege and (mostly) free to run

## Repo structure

```
.
├── terraform/   # AWS account structure: IAM, VPC/SGs/NACLs, KMS (see terraform/README.md)
└── src/         # Lambda application source — not built yet
```

## Build log

This repo is being built in public as part of a 30-week certification + build
plan. Current milestone: **Weeks 1–4 (AWS SAA-C03)** — account structure, IAM,
VPC, cost guardrails.

## License

MIT — see [LICENSE](LICENSE).
