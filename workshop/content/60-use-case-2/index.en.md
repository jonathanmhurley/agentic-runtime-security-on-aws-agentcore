---
title: 'Use Case 2 — User intent via OAuth (OBO)'
weight: 60
---

A personalized read agent. The user logs in through the OIDC IdP (Cognito) with **Authorization Code + PKCE**. **AgentCore performs on-behalf-of token exchange** so the user's identity rides the JWT to Vault, which authorizes per-user and vends a scoped dynamic DB credential. Personalized read from RDS.

OBO reduces to one credential-provider config plus two runtime calls (`get-workload-access-token-for-jwt` → `get-resource-oauth2-token`).
