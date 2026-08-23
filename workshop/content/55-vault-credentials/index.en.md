---
title: 'Vault — JWT authentication & dynamic credentials'
weight: 55
---

## What you'll prove

The full **HashiCorp Vault Agentic pattern**: present a JWT, Vault validates it
(JWKS + subject binding), and vends short-lived scoped AWS credentials — with no
standing privileges and a clear audit trail.

This builds on Use Case 1's agent identity: the same JWT that Gateway validated is
now validated by **real Vault Enterprise**, and the credential comes from Vault's
dynamic secrets engine instead of an IAM execution role.

## The trust path

1. **Mint a JWT** — signed with the workshop's RS256 keypair, carrying `sub: uc1-agent`,
   `aud: vault-standin`, and a unique `jti`.
2. **Authenticate to Vault** — present the JWT to `auth/jwt/login`. Vault fetches the
   public key from the GitHub-hosted JWKS, verifies the signature, checks `aud`,
   confirms `sub` matches the role's `bound_subject`, and returns a short-lived Vault
   token with the `uc1` policy.
3. **Read scoped credentials** — use the Vault token to read `aws/sts/bedrock-reader`.
   Vault calls `sts:AssumeRole` into a scoped role and returns 15-minute STS credentials.
4. **Access the protected resource** — use those credentials to call `bedrock:Retrieve`
   on the Knowledge Base.

## Control objectives demonstrated

- **OBJ-1** — verifiable agent identity (JWT `sub` validated against `bound_subject`)
- **OBJ-2** — no standing privileges (credentials are 15m TTL, lease-bound)
- **OBJ-4** — enforcement at the point of use (Vault policy + bound_subject)
- **OBJ-5** — audit trail (Vault logs every authentication + credential issuance)

## Prerequisites

- Vault Enterprise 2.0.4+ running and reachable (see `infrastructure/modules/vault_server/deploy-vault-dev.sh`)
- JWT auth method enabled and configured (bootstrap commands below)
- AWS secrets engine with `bedrock-reader` role configured
- The `uc1` policy: `path "aws/sts/bedrock-reader" { capabilities = ["read", "update"] }`

## Vault bootstrap (one-time setup)

```bash
export VAULT_ADDR=http://<VAULT_IP>:8200
export VAULT_TOKEN=<ROOT_TOKEN>

# Enable JWT auth
vault auth enable jwt

# Configure to trust the workshop JWKS
vault write auth/jwt/config \
  jwks_url="https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin/jwks.json" \
  default_role="uc1-agent"

# Create the uc1-agent role (bound_subject = the Agent Registry equivalent)
vault write auth/jwt/role/uc1-agent \
  role_type="jwt" \
  bound_audiences="vault-standin" \
  bound_subject="uc1-agent" \
  user_claim="sub" \
  token_policies="uc1" \
  token_ttl="15m"

# Policy
vault policy write uc1 - <<'EOF'
path "aws/sts/bedrock-reader" { capabilities = ["read", "update"] }
EOF

# AWS secrets engine
vault secrets enable -path=aws aws
vault write aws/config/root \
  access_key="<AWS_ACCESS_KEY>" \
  secret_key="<AWS_SECRET_KEY>" \
  region=us-east-1
vault write aws/roles/bedrock-reader \
  credential_type=assumed_role \
  role_arns="arn:aws:iam::<ACCOUNT_ID>:role/Stage2VendedKBReadRole" \
  default_sts_ttl=900
```

## Step 1 — Mint a JWT

```bash
cd applications/vault-standin
JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin" \
  --scopes kb:read --kid stage2-key-1 --ttl 900)"
```

> **Important:** the JWT must include a `jti` claim (unique per token). Vault 2.0.4
> requires it for schema validation. `mint-jwt.py` adds this automatically.

## Step 2 — Authenticate to Vault

```bash
vault write auth/jwt/login role=uc1-agent jwt="$JWT"
```

Expected: Vault returns a token with `token_policies: ["default", "uc1"]`.

## Step 3 — Read scoped credentials

```bash
VAULT_TOKEN="$(vault write -field=token auth/jwt/login role=uc1-agent jwt="$JWT")" \
  vault read aws/sts/bedrock-reader
```

Expected: STS credentials with `assumed-role/Stage2VendedKBReadRole/vault-jwt-uc1-agent-...`, TTL 15m.

## Step 4 — Access the Knowledge Base

```bash
eval "$(vault write -format=json -field=token auth/jwt/login role=uc1-agent jwt="$JWT" | \
  xargs -I{} vault read -format=json aws/sts/bedrock-reader | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print(f'export AWS_ACCESS_KEY_ID={d[\"access_key\"]}')
print(f'export AWS_SECRET_ACCESS_KEY={d[\"secret_key\"]}')
print(f'export AWS_SESSION_TOKEN={d[\"security_token\"]}')
")"
aws bedrock-agent-runtime retrieve \
  --knowledge-base-id QLKOTZM2GC \
  --retrieval-query '{"text":"What is RapidLane same-day SLA?"}' \
  --region us-east-1 --query "retrievalResults[0].content.text" --output text
```

Expected: the Meridian SLA answer (6 hours if booked before 11 AM).

## Negative test — unregistered agent denied

```bash
BADJWT="$(python3 tools/mint-jwt.py --sub not-registered --aud vault-standin \
  --iss "https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin" \
  --scopes kb:read --kid stage2-key-1 --ttl 900)"
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
| Entity alias | Auto-created on first login | Manual pre-creation (undocumented, currently broken in 2.0.4) |
| Allowlist | `bound_subject` on role | Agent Registry |
| RAR support | No | Yes (`authorization_details` claim) |
| Workshop fit | Excellent — authentication step is visible and teachable | Better for UC2/UC3 when RAR matters |

The OAuth RS + Agent Registry is the target for UC2/UC3 (where delegation and RAR
claims add value). For UC1's "does Vault validate my JWT and vend scoped creds?" proof,
the JWT auth method is simpler, GA, and demonstrates the same security controls.
