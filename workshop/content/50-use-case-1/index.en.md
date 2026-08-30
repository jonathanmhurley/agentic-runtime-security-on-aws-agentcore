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

Mint a JWT with the workshop keypair and call the Gateway. These variables should
already be set from the [Deploy the foundation](../30-deploy-foundation/) steps:

```bash
cd ~/agentic-runtime-security-on-aws-agentcore/applications/vault-standin

GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways --region us-east-1 \
  --query "items[?contains(name,'workshop-gateway')].gatewayId | [0]" --output text)
GATEWAY_URL="https://${GATEWAY_ID}.gateway.bedrock-agentcore.us-east-1.amazonaws.com"

JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "$ISSUER" --scopes kb:read --kid stage2-key-1 --ttl 900)"

curl -s -X POST "${GATEWAY_URL}/mcp" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"kb-retrieve___retrieve_from_kb","arguments":{"query":"What is RapidLane same-day SLA?"}},"id":1}' \
  | python3 -m json.tool
```

## The Vault path (JWT → scoped STS credentials)

The same JWT authenticates to Vault, which validates it, checks the `bound_subject`
(the Agent Registry equivalent), and vends short-lived STS credentials scoped to KB read.

### Try it

```bash
# Mint a fresh JWT (tokens expire after 15 minutes):
JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "$ISSUER" --scopes kb:read --kid stage2-key-1 --ttl 900)"

# Login to Vault — returns a scoped token with the uc1 policy:
vault write auth/jwt/login role=uc1-agent jwt="$JWT"

# Negative test — unregistered agent is denied:
BADJWT="$(python3 tools/mint-jwt.py --sub not-registered --aud vault-standin \
  --iss "$ISSUER" --scopes kb:read --kid stage2-key-1 --ttl 900)"
vault write auth/jwt/login role=uc1-agent jwt="$BADJWT"
# Expected: "invalid subject (sub) claim"

# Get KB ID before Vault STS creds override your shell credentials:
KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 \
  --query "knowledgeBaseSummaries[?contains(name,'meridian')].knowledgeBaseId | [0]" --output text)

# Login to Vault and vend STS creds:
export VAULT_TOKEN="$(vault write -field=token auth/jwt/login role=uc1-agent jwt="$JWT")"

eval "$(vault write -format=json aws/sts/bedrock-reader ttl=15m | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(f'export AWS_ACCESS_KEY_ID={d[\"access_key\"]}')
print(f'export AWS_SECRET_ACCESS_KEY={d[\"secret_key\"]}')
print(f'export AWS_SESSION_TOKEN={d[\"security_token\"]}')
")"

aws bedrock-agent-runtime retrieve \
  --knowledge-base-id "$KB_ID" \
  --retrieval-query '{"text":"What is RapidLane same-day SLA?"}' \
  --region us-east-1 --query "retrievalResults[0].content.text" --output text

# IMPORTANT: The eval above exported Vault-vended STS credentials into your
# shell environment. These override CloudShell's default credentials, so any
# subsequent AWS CLI calls would run as Stage2VendedKBReadRole (read-only KB
# access) instead of your workshop participant role. Unset them now to restore
# full permissions for the remaining workshop steps.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

## Design choice: managed Knowledge Base

The KB uses **Amazon Bedrock managed embeddings** (zero-config). For a workshop about
agent security, the KB is a supporting actor — the star is how the agent *reaches* it
with a scoped, short-lived credential. The managed KB stands up in 3 API calls and
keeps focus on identity and least-privilege.

## Control objectives established

- **OBJ-1** — verifiable agent identity (JWT validated by Gateway via JWKS)
- **OBJ-1** — same JWT validates against Vault (JWKS trust)
- **OBJ-2** — no standing privileges (Gateway brokers the credential; caller never
  holds `bedrock:Retrieve` directly; Vault vends short-lived STS creds)
- **OBJ-4** — enforcement at the point of use (Gateway validates before routing)
- **OBJ-5** — negative test proves unregistered agents are denied
