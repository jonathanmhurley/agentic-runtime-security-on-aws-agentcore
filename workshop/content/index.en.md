---
title: 'Agentic Runtime Security on AWS — AgentCore Edition'
weight: 0
---

Welcome. This workshop demonstrates the five control objectives for AI agentic
systems — verifiable agent identity, no standing privileges, actions tied to user
intent, enforcement at the point of use, and a single correlated audit trail —
using **Amazon Bedrock AgentCore** and **HashiCorp Vault Enterprise** on AWS.

## What you'll do

1. **Deploy an agent** on AgentCore Runtime with a verifiable workload identity
2. **Prove scoped access via Gateway** — present a JWT, Gateway validates it and
   brokers access to a Knowledge Base without the caller holding credentials directly
3. **Prove dynamic credentials via Vault** — present the same JWT to Vault, which
   validates it (JWKS + subject binding) and vends short-lived STS credentials
4. **Verify enforcement** — show that unregistered agents are denied

## What you'll build

Three progressively-layered Strands agents on AgentCore Runtime:

1. **Use Case 1** — Non-personalized read-only agent (agent workload identity,
   scoped credentials via Gateway and Vault)
2. **Use Case 2** *(coming)* — OAuth personalized read agent (user intent via OIDC +
   PKCE, on-behalf-of)
3. **Use Case 3** *(coming)* — Privileged write with single-plane Vault audit
   correlation

## Duration

Approximately **2 hours** for UC1 (Gateway + Vault).
