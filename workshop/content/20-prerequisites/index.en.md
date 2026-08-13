---
title: 'Prerequisites'
weight: 20
---

## What's needed today (Stages 0-2b)

- **AWS account** with Amazon Bedrock AgentCore enabled (us-east-1)
- **Bedrock model access**: `amazon.nova-pro-v1:0` (Nova Pro via CRIS) and
  `amazon.nova-2-multimodal-embeddings-v1:0` (managed KB embeddings)
- **Node.js 20+** (for the AgentCore CLI: `npm install -g @aws/agentcore`)
- **Python 3.10+** + `pyjwt`, `cryptography` (for JWT minting tools)
- **AWS CLI** with a profile configured for the target account

## What's needed for Stage 3 (Vault — not yet deployed)

- **HashiCorp Vault Enterprise license** — required for the Agent Registry (beta).
  Provided by Oscar/content team, injected at deploy from a content-team-owned secret.
- The license is stored locally at `infrastructure/modules/vault_server/vault.hclic`
  (gitignored — never committed).

> No IVIA/IBM licensing in this edition.

## Version pinning

This workshop is validated against pinned versions. See the "Tested against" block in
`docs/DESIGN.md` §7. Do not float to `latest`.
