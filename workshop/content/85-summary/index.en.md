---
title: 'Summary'
weight: 85
---

## What's proven today

You deployed an agent on AgentCore Runtime that reads a managed Knowledge Base
through the **native AgentCore Gateway credential flow**: JWT validated via OIDC
discovery + JWKS, Gateway brokers scoped access via its IAM role, and the caller
never holds the downstream credential directly. Same principle as Vault's Agentic
pattern (present token → validate → scoped credential), running on native AWS
primitives.

## What's next

- **Stage 3:** real Vault Enterprise (Agent Registry + dynamic secrets + audit)
- **UC2:** user identity via OIDC + PKCE + AgentCore OBO
- **UC3:** privileged write with single-plane Vault audit correlation

See `docs/VAULT_HANDOFF.md` for the Stage 3 pickup.
