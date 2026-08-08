---
title: 'Deploy the foundation'
weight: 30
---

Deploy in three tiers with `deploy-workshop.sh --tier <n>` (idempotent, re-runnable):

- **Tier 1** — foundation: VPC (slim), RDS, Bedrock KB, IAM, audit, Vault IAM/KMS.
- **Tier 2** — Vault Enterprise server + Vault config (JWT auth against AgentCore JWKS, dynamic secrets engines, Agent Registry, policies).
- **Tier 3** — AgentCore setup (Runtime agents, Identity, OBO credential provider) + OIDC IdP (Cognito) wiring.
