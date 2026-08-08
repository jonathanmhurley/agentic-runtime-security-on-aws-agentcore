---
title: 'Agentic Runtime Security on AWS — AgentCore Edition'
weight: 0
---

Welcome. Over ~2 hours you will deploy the five control objectives for AI agentic systems — verifiable agent identity, no standing privileges, actions tied to user intent, enforcement at the point of use, and a single correlated audit trail — using **Amazon Bedrock AgentCore + HashiCorp Vault Enterprise** on AWS. No EKS, no IVIA.

## What you'll build

Three progressively-layered Strands agents on AgentCore Runtime, brokered through Vault:

1. **Use Case 1** — Non-personalized read-only agent (agent workload identity, JIT credentials)
2. **Use Case 2** — OAuth personalized read agent (user intent via OIDC + PKCE, carried on-behalf-of)
3. **Use Case 3** — Privileged write with single-plane Vault audit correlation
