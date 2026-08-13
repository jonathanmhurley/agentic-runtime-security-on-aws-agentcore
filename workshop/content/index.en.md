---
title: 'Agentic Runtime Security on AWS — AgentCore Edition'
weight: 0
---

Welcome. This workshop demonstrates the five control objectives for AI agentic
systems — verifiable agent identity, no standing privileges, actions tied to user
intent, enforcement at the point of use, and a single correlated audit trail —
using **Amazon Bedrock AgentCore** on AWS, with **HashiCorp Vault Enterprise** as
the secrets/authorization backbone.

## Current status

**Proven and deployable today (Stages 0-2b):**
- Agent on AgentCore Runtime (Strands, Nova Pro)
- Agent reads a managed Bedrock KB via a scoped credential
- AgentCore Gateway validates a JWT (via OIDC discovery + JWKS) and brokers
  scoped access to a downstream target — the native Agentic credential flow

**Coming next (Stage 3+):**
- Real Vault Enterprise: Agent Registry + dynamic secrets + single audit trail
- UC2: user intent via OIDC + PKCE + AgentCore OBO
- UC3: privileged write with Vault audit correlation

See `docs/RUNBOOK.md` for the exact commands to reproduce everything proven so far.

## What you'll build (target architecture)

Three progressively-layered Strands agents on AgentCore Runtime:

1. **Use Case 1** — Non-personalized read-only agent (agent workload identity, JIT credentials)
2. **Use Case 2** — OAuth personalized read agent (user intent via OIDC + PKCE, on-behalf-of)
3. **Use Case 3** — Privileged write with single-plane Vault audit correlation
