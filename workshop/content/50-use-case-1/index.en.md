---
title: 'Use Case 1 — Workload identity & scoped access'
weight: 50
---

## What you'll prove

A non-personalized, read-only agent on **AgentCore Runtime** answers questions from
the Bedrock Knowledge Base. The agent acts as *itself* (no end-user identity yet).
This establishes the agent-identity + scoped-credential backbone that UC2 and UC3
build on.

## The Gateway path (native AgentCore)

The agent's identity is verified and access is brokered through **AgentCore Gateway**:

1. **Mint a JWT** — signed with the workshop RS256 keypair, carrying `sub: uc1-agent`
   and a unique `jti`.
2. **Present it to the Gateway** — Gateway's `CUSTOM_JWT` inbound authorizer validates
   the signature (via OIDC discovery + JWKS), checks the audience, and accepts.
3. **Gateway routes the tool call** to the KB target Lambda using its own IAM role
   (`GATEWAY_IAM_ROLE` outbound auth) — the caller never holds `bedrock:Retrieve`.
4. **The KB answers** — Meridian SLA passages are returned.

### Try it

```bash
cd ~/agentic-runtime-security-on-aws-agentcore/applications/vault-standin
JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "<ISSUER>" --scopes kb:read --kid stage2-key-1 --ttl 900)"
curl -s -X POST "<GATEWAY_URL>/mcp" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"kb-retrieve___retrieve_from_kb","arguments":{"query":"What is RapidLane same-day SLA?"}},"id":1}'
```

Or use the demo script: `bash demo.sh`

## Design choice: managed Knowledge Base

The KB uses **Amazon Bedrock managed embeddings** (zero-config). For a workshop about
agent security, the KB is a supporting actor — the star is how the agent *reaches* it
with a scoped, short-lived credential. The managed KB stands up in 3 API calls and
keeps focus on identity and least-privilege.

## Control objectives established

- **OBJ-1** — verifiable agent identity (JWT validated by Gateway via JWKS)
- **OBJ-2** — no standing privileges (Gateway brokers the credential; caller never
  holds `bedrock:Retrieve` directly)
- **OBJ-4** — enforcement at the point of use (Gateway validates before routing)

## What's next

The next section proves the same flow through **real Vault Enterprise** — the JWT
authenticates to Vault, Vault validates it, checks the `bound_subject` (the Agent
Registry equivalent), and vends short-lived scoped STS credentials. Same agent
identity, stronger governance.
