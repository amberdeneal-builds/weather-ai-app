# Weather AI (Aeris)

**Live right now:** `https://api.amberdeneal.dev/?lat=39.2904&lon=-76.6122&city=Baltimore`

A serverless weather API that writes you a short, human insight about your day — and
keeps doing it even when the AI service behind it goes down, because it quietly fails
over to a second cloud.

Ask it for a location and you get current conditions and today's forecast from the
National Weather Service, plus a couple of sentences on what to expect and what to
plan around. That insight normally comes from Amazon Bedrock. If Bedrock fails for
any reason, the same request is served by Google Vertex AI instead, and you'd never
know the difference from the response.

This is the public half of a two-project, multi-cloud certification program
(AWS SAA-C03 → GCP PCA/PDE/PMLE → AWS GenAI Dev Pro), built in the spirit of Forrest
Brazeal's Cloud Resume Challenge.

**Want to see the intended UX?** There's a front-end prototype with dummy data here:
https://claude.ai/code/artifact/e45f8211-c509-499f-99ac-07f522351aa4

---

## How it's put together

```
       Cloudflare DNS
             │
   api.amberdeneal.dev  (ACM cert, API Gateway custom domain)
             │
      API Gateway HTTP API  ── ANY /  ──▶  Lambda (Python 3.13)
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    ▼                         ▼                         ▼
              DynamoDB cache          api.weather.gov            Amazon Bedrock
              (on-demand, TTL)        (NWS, no API key)       Claude Haiku 4.5
                                                                        │
                                                              on failure ▼
                                                          GCP Vertex AI
                                                          Gemini 2.5 Flash
```

| Layer | Choice | Worth knowing |
|---|---|---|
| API | API Gateway HTTP API + custom domain | Terraform-managed — **imported** from console-created resources, so a live domain never went down |
| Compute | Lambda, Python 3.13, **not** VPC-attached | There's a good story here — see below |
| Cache | DynamoDB, on-demand, TTL-based | Key is `weather#{lat},{lon}` rounded to 2 decimals |
| Weather data | National Weather Service | Free, no API key, US-only |
| AI (primary) | Bedrock — Claude Haiku 4.5 | Via the `us.` cross-Region inference profile |
| AI (failover) | Vertex AI — Gemini 2.5 Flash | Direct REST call; no Cloud Run in front of it |
| Secrets | Secrets Manager + customer-managed KMS key | Rotation enabled |
| DNS | Cloudflare — registrar **and** DNS host | Not Route 53, and there's a reason |

---

## The decisions behind it

Anyone can list services. These are the calls that actually took thought, including
the ones I got wrong the first time.

### Why the Lambda left its VPC

It started in private subnets with no NAT gateway, reaching AWS services through VPC
endpoints. That's a genuinely good design — right up until the function needed a
*third-party* API. `api.weather.gov` lives on the public internet, and VPC endpoints
can't reach it at all.

So the choice was a NAT gateway at roughly **$32/month** for a portfolio app, or
dropping the VPC attachment. DynamoDB, Bedrock, Secrets Manager and KMS are all
regional AWS APIs reachable through IAM alone, and this function never touches
anything living *inside* a VPC — so the attachment was buying nothing real. Dropping
it also let the execution role shed its ENI permissions and made a **~$7/month**
CloudWatch Logs interface endpoint unnecessary.

The VPC in `terraform/vpc.tf` is still deployed and still correct. It's just no
longer in the request path, and that's the honest state of it.

### Cross-Region inference profiles change the IAM shape

Claude Haiku 4.5 isn't available for direct in-region invocation in `us-east-1` — you
reach it only through a geographic inference profile. AWS then checks permission
against **both** the profile ARN you name *and* the underlying foundation-model ARN in
whichever region the profile routes to.

That means two IAM statements rather than one, with the second scoped by a
`bedrock:InferenceProfileArn` condition so the model can't be called directly and
bypass the profile. Easy to miss until an invocation fails in a region you weren't
thinking about.

### The failover is verified, not assumed

`get_ai_insight()` logs which provider served each request, which makes this
checkable rather than merely plausible.

To prove it, I set the Bedrock model ID to something invalid on purpose. CloudWatch
showed the real `ValidationException`, then
`ai_insight served by: vertex (bedrock failover)` — with the API still returning a
complete response to the caller. Reverting the model ID brought back
`ai_insight served by: bedrock`. **Both directions confirmed with logs.**

### DNS lives on Cloudflare on purpose

Route 53 domain *registration* is blocked on Free Tier accounts, so the domain was
registered with Cloudflare Registrar — and Cloudflare Registrar domains can't use
third-party nameservers, which rules out a Route 53 hosted zone entirely. Every
record (the ACM validation CNAME, the `api` CNAME) lives in Cloudflare with the proxy
off. Terraform reads the existing certificate as a data source but manages no DNS.

Not the original plan. A real constraint, handled.

---

## Repo structure

```
.
├── iam/          # terraform-deployer's own IAM policies — documentation of what's
│                 # live in the account, applied via CLI rather than Terraform.
│                 # iam/README.md explains that bootstrapping split.
├── src/
│   ├── handler.py        # weather fetch + AI insight + caching
│   └── requirements.txt  # google-auth, requests — pure-Python, vendored into the zip
└── terraform/    # everything AWS-side: IAM role, VPC, KMS, DynamoDB, Secrets
                  # Manager, Lambda, API Gateway, Budgets. See terraform/README.md.
```

---

## What it costs to run

About **$4/month account-wide** before free-tier credits — and most of that isn't
even this project. The two largest line items in August were an unrelated EC2 test
instance and a CloudWatch Logs interface endpoint that's since been switched off.
This app's own footprint is genuinely pennies: KMS and Secrets Manager together came
to **under a cent**.

The guardrails are both architectural and alert-based:

- Interface VPC endpoints sit behind an off-by-default toggle
- DynamoDB is on-demand rather than provisioned
- The Lambda log group has a **14-day** retention cap, so it can't quietly balloon
- Budget alerts on both clouds — AWS via `terraform/budgets.tf`, GCP via
  `gcloud billing budgets`

**One measurement gotcha worth passing along:** `aws ce get-cost-and-usage` nets
free-tier credits against charges by default, so it will cheerfully report `$0.00`
while your resources are genuinely costing money. Add
`--filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}'` to see the real
run-rate. That distinction is the difference between "my bill is zero" and "my
resources cost nothing," and they are not the same sentence.

---

## Known gaps

Stating these plainly, because a gap you've named is a roadmap item and a gap you
haven't is a surprise.

- **Cross-cloud auth uses a long-lived service-account key.** The Vertex AI failover
  authenticates with a GCP service-account JSON key held in Secrets Manager. It's
  KMS-encrypted and never touches the repo, but it's still a standing credential.
  Migrating to **Workload Identity Federation** — so the Lambda's own AWS identity
  exchanges for short-lived GCP tokens and the key can be deleted outright — is the
  next planned change.
- No front-end yet; S3 + CloudFront for the static site is still ahead.
- No CI/CD pipeline yet (GitHub Actions running `pytest`, lint, and `terraform plan`
  on push is planned).
- Test coverage is thin.
- US-only, because the National Weather Service is US-only.

---

## Build log

Built in public as part of a 33-week certification and build plan. The AWS core —
IAM, VPC, KMS, DynamoDB, Lambda, API Gateway, custom domain, cost guardrails — and
the GCP Vertex AI failover are complete and running.

Questions about any of the decisions above are welcome; the reasoning is the most
useful part of this repo. Thanks for reading!

## License

MIT — see [LICENSE](LICENSE).
