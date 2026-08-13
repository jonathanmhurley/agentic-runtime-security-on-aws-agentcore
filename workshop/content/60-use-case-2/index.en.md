---
title: 'Use Case 2 — User intent via OAuth (OBO)'
weight: 60
---

> **Status: not yet built.** This use case requires an OIDC IdP (Cognito or
> equivalent) + the AgentCore on-behalf-of (OBO) token exchange. The OBO flow is
> documented in `docs/DESIGN.md` §4 (marked "documented, NOT yet proven").

## What UC2 will demonstrate

A personalized read agent. The user logs in through an OIDC IdP with
**Authorization Code + PKCE**. AgentCore performs **on-behalf-of token exchange**
so the user's identity rides the JWT to Vault, which authorizes per-user and vends
a scoped dynamic DB credential. Personalized read from RDS.

## Prerequisite for building UC2

Confirm the real AgentCore Identity issuer / JWKS URL / claim shape — this is the
one genuinely unproven input everything else keys off. See `docs/VAULT_HANDOFF.md` §2.
