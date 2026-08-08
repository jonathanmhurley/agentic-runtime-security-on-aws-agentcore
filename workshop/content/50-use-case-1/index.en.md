---
title: 'Use Case 1 — Workload identity & JIT credentials'
weight: 50
---

## What you'll build

A non-personalized, read-only Strands agent on **AgentCore Runtime** that answers
questions from the Bedrock Knowledge Base. There is **no end-user identity** yet —
the agent acts as *itself*. This establishes the agent-identity + JIT-credential
backbone that UC2 (user intent) and UC3 (privileged write) build on.

## Design choice: a fully-managed Knowledge Base

The knowledge base here is an **Amazon Bedrock *managed* Knowledge Base**
(`type: MANAGED`, managed embeddings). We chose this deliberately, and it is worth
calling out because it is a large simplification over the traditional path.

| Traditional (self-managed) KB | Managed KB (used here) |
| --- | --- |
| Provision an OpenSearch Serverless collection + vector index | None — the vector store is fully managed |
| Choose + wire an embedding model, set dimensions | Managed embeddings, zero config |
| Configure chunking / parsing strategy | Sensible managed defaults |
| Multiple IAM roles + data-access policies for AOSS | One KB service role |
| ~a module's worth of Terraform | **3 API calls**: create KB → add S3 data source → start ingestion |

For a workshop about **agent runtime security**, the KB is a supporting actor — the
star is how the agent *reaches* it with a scoped, short-lived credential. The
managed KB lets us stand up a working retrieval target in minutes and keep the
focus on identity and least-privilege, not on operating a vector database. The
trade-off is less control over the retrieval internals (the vector store is opaque),
which is exactly the right trade for this use case.


## The trust path

1. The agent obtains its **AgentCore workload-identity JWT** from AgentCore Identity.
2. It presents that JWT **directly as the Vault token** (`X-Vault-Token`). Vault's
   OAuth resource server (profile `agentcore`) validates it against the **AgentCore
   JWKS endpoint** and checks the **Agent Registry** (`uc1-agent` registered + approved).
   There is no Vault login round-trip and no Kubernetes auth.
3. Vault vends a short-lived, **SELECT-only** DB credential (`uc1-readonly`, TTL 15m)
   and scoped **Bedrock STS** creds (`aws/sts/bedrock-reader`).
4. The agent uses those JIT creds to retrieve from the Knowledge Base and answer.

## Control objectives established

- **OBJ-1** — verifiable agent identity (AgentCore JWT validated by Vault via JWKS).
- **OBJ-2** — no standing privileges (every credential is JIT, TTL-bound, auto-revoked).
- **OBJ-4** — enforcement at the point of use (Vault authorizes at issue time).

## Deploy

```bash
# Tier 3 provisions the AgentCore Runtime agent + workload identity.
bash infrastructure/scripts/deploy-workshop.sh --tier 3
```

## Verify

```bash
# The uc1-readonly role exists and is SELECT-only
vault read database/creds/uc1-readonly

# The agent answers from the KB (no user context)
#   -> returns retrieved passages; writes are impossible with these creds
```

> **Version note:** the Agent Registry is **beta** (Vault Enterprise). This lab is
> validated only against the pinned Vault Enterprise + provider versions — see the
> "Tested against" block in the design doc. Do not float to `latest`.
