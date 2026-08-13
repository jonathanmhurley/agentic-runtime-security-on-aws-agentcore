# Infrastructure (FUTURE STATE — not yet functional)

> **These Terraform modules are stubs.** They describe the *eventual* packaged
> workshop deployment but contain no real resources today. Actual deployment uses
> the **AgentCore Node CLI** (`agentcore create/deploy/invoke`) — see `docs/RUNBOOK.md`.
>
> Do NOT run `terraform apply` against these modules — they will fail.

## When will these become real?

When the workshop is packaged for attendee delivery (Workshop Studio / Instruqt), the
tiered Terraform deploy (`deploy-workshop.sh --tier 1/2/3`) will replace the manual CLI
steps. Until then, the CLI is the authoritative deploy path and these modules are a
design reference only.

## Module status

| Module | Status | What it will do |
|---|---|---|
| `vault_server/` | Stub (README only) | Self-hosted Vault Enterprise on EC2/Fargate |
| `vault_config/` | **Spec written** (main.tf) | OAuth resource server + Agent Registry + secrets engines |
| `vault_iam/` | Stub | Vault → Bedrock STS assume + KMS unseal |
| `agentcore_identity/` | Stub (null_resource) | AgentCore workload identity provisioning |
| `agentcore_runtime/` | Stub (null_resource) | AgentCore Runtime agent provisioning |
| `agentcore_obo/` | Stub (README only) | OBO credential provider |
| `oidc_idp/` | Stub (README only) | External OIDC IdP (Cognito) |
| `audit/` | Stub (README only) | Single hash-chained Vault audit stream |
| `rds/` | Stub (README only) | PostgreSQL + pgaudit |
| `bedrock_kb_aoss/` | Stub (README only) | Bedrock KB — superseded by managed KB in `applications/stage1-kb/` |
| `bedrock_kb_index/` | Stub (README only) | Vector index — superseded by managed KB |
| `ecr/` | Stub (README only) | ECR repos for agent container images |
| `vpc/` | Stub (README only) | VPC (slim, Vault reachability only) |
| `observability/` | Stub (README only) | CloudWatch dashboards |

## The one module worth reading now

**`vault_config/main.tf`** is the real target spec for Stage 3 (Vault Enterprise). It
defines the OAuth resource server profile, the Agent Registry, dynamic secrets engines,
and policies. This is what Oscar applies when the license + Vault server are ready. See
`docs/VAULT_HANDOFF.md`.
