---
title: 'Vault — JWT authentication & dynamic credentials'
weight: 55
---

## What you'll prove

The full **HashiCorp Vault Agentic pattern**: present a JWT, Vault validates it
(JWKS + subject binding), and vends short-lived scoped AWS credentials with no
standing privileges and a clear audit trail.

This builds on Use Case 1's agent identity: the same JWT that Gateway validated is
now validated by **real Vault Enterprise**, and the credential comes from Vault's
dynamic secrets engine instead of an IAM execution role.

## The trust path

1. **Mint a JWT** — signed with the workshop's RS256 keypair, carrying `sub: uc1-agent`,
   `aud: vault-standin`, and a unique `jti`.
2. **Authenticate to Vault** — present the JWT to `auth/jwt/login`. Vault fetches the
   public key from your mock server's JWKS, verifies the signature, checks `aud`,
   confirms `sub` matches the role's `bound_subject`, and returns a short-lived Vault
   token with the `uc1` policy.
3. **Vend scoped credentials** — use the Vault token to call `aws/sts/bedrock-reader`.
   Vault calls `sts:AssumeRole` into a scoped role and returns 15-minute STS credentials.
4. **Access the protected resource** — use those credentials to call `bedrock:Retrieve`
   on the Knowledge Base.

## Control objectives demonstrated

- **OBJ-1** — verifiable agent identity (JWT `sub` validated against `bound_subject`)
- **OBJ-2** — no standing privileges (credentials are 15m TTL, lease-bound)
- **OBJ-4** — enforcement at the point of use (Vault policy + bound_subject)
- **OBJ-5** — audit trail (Vault logs every authentication + credential issuance)

## Prerequisites

These should already be completed from the [Deploy the foundation](../30-deploy-foundation/) steps:

- Vault Enterprise running and reachable (`$VAULT_ADDR` and `$VAULT_TOKEN` set)
- JWT auth method enabled and configured against your mock server's JWKS
- AWS secrets engine with `bedrock-reader` role configured
- `$ISSUER` and `$JWKS_URL` variables set from Step 3 of the foundation

## Step 1 — Mint a JWT

```bash
cd ~/agentic-runtime-security-on-aws-agentcore/applications/vault-standin

JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "$ISSUER" --scopes kb:read --kid stage2-key-1 --ttl 900 --client-id workshop-client)"
```

> **Note:** the JWT expires after 15 minutes. If you see "token is expired" in later
> steps, re-mint with the command above.

## Step 2 — Authenticate to Vault

```bash
vault write auth/jwt/login role=uc1-agent jwt="$JWT"
```

Expected: Vault returns a token with `token_policies: ["default", "uc1"]`.

## Step 3 — Vend scoped credentials and query the KB

Look up the KB ID first (before Vault STS creds override your shell credentials),
then login, vend, and retrieve in one flow:

```bash
# Get KB ID while CloudShell default creds are still active:
KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 \
  --query "knowledgeBaseSummaries[?contains(name,'meridian')].knowledgeBaseId | [0]" --output text)

# Login to Vault and vend STS creds:
# (mint a fresh JWT — the Step 2 login consumed the earlier one)
JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "$ISSUER" --scopes kb:read --kid stage2-key-1 --ttl 900 --client-id workshop-client)"

export VAULT_TOKEN="$(vault write -field=token auth/jwt/login role=uc1-agent jwt="$JWT")"

eval "$(vault write -format=json aws/sts/bedrock-reader ttl=15m | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(f'export AWS_ACCESS_KEY_ID={d[\"access_key\"]}')
print(f'export AWS_SECRET_ACCESS_KEY={d[\"secret_key\"]}')
print(f'export AWS_SESSION_TOKEN={d[\"security_token\"]}')
")"

# Query KB with Vault-vended creds:
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
export VAULT_TOKEN="workshop-root-token"
```

Expected: the Meridian SLA answer (6 hours if booked before 11 AM).

## Negative test — unregistered agent denied

```bash
BADJWT="$(python3 tools/mint-jwt.py --sub not-registered --aud vault-standin \
  --iss "$ISSUER" --scopes kb:read --kid stage2-key-1 --ttl 900 --client-id workshop-client)"
vault write auth/jwt/login role=uc1-agent jwt="$BADJWT"
```

Expected: `error validating token: invalid subject (sub) claim` — the `bound_subject`
enforcement rejects agents not on the allowlist.

## Design note: JWT auth method vs. OAuth Resource Server

This workshop uses Vault's GA **JWT auth method** (`auth/jwt/`) rather than the beta
**OAuth Resource Server** (`sys/config/oauth-resource-server/`). Both validate the same
JWT against the same JWKS; the difference is:

| | JWT auth method (used here) | OAuth Resource Server (beta) |
|---|---|---|
| Maturity | GA, stable | Beta (2.0.3+) |
| Login step | Explicit `auth/jwt/login` → Vault token | Direct `X-Vault-Token` passthrough (no login step) |
| Entity alias | Auto-created on first login | Manual pre-creation (broken in 2.0.4) |
| Allowlist | `bound_subject` on role | Agent Registry |
| RAR support | No | Yes (`authorization_details` claim) |
| Workshop fit | Excellent — authentication step is visible and teachable | Better for UC2/UC3 when RAR matters |
