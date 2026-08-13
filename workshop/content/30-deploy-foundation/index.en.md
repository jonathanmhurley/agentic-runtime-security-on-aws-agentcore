---
title: 'Deploy the foundation'
weight: 30
---

> **Status:** the tiered `deploy-workshop.sh --tier <n>` flow described below is the
> *eventual* packaged workshop form. It is **not yet built**. Today's working deploy
> uses the AgentCore CLI directly — see `docs/RUNBOOK.md`.

## Eventual tiered deploy (target state)

- **Tier 1** — foundation: VPC (slim), RDS, Bedrock KB, IAM, audit, Vault IAM/KMS.
- **Tier 2** — Vault Enterprise server + Vault config (JWT auth, secrets engines,
  Agent Registry, policies).
- **Tier 3** — AgentCore setup (Runtime agents, Identity, OBO credential provider) +
  OIDC IdP wiring.

## What works today

Follow `docs/RUNBOOK.md` Stages 0-2b. The foundation is deployed via:
- `agentcore create` + `agentcore deploy` (Runtime + Gateway)
- `applications/stage1-kb/create-kb.sh` (managed Bedrock KB)
- `applications/gateway-kb-target/deploy.sh` (Gateway Lambda target)
