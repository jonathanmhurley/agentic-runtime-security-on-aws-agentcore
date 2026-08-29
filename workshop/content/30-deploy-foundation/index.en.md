---
title: 'Deploy the foundation'
weight: 30
---

## What you'll deploy

Five components that form the foundation for the workshop's security demonstrations:

1. **AgentCore Runtime agent** (Strands, Nova Pro) — the AI agent with a workload identity
2. **A managed Bedrock Knowledge Base** — the protected resource the agent reads from
3. **A workshop keypair + mock OAuth server** — issues and validates JWTs for the workshop
4. **An AgentCore Gateway** — validates inbound JWTs and brokers scoped access to targets
5. **Vault Enterprise** — validates JWTs and vends dynamic credentials

> **Before you start:** complete the [Prerequisites](../20-prerequisites/) section
> (clone the repo, run the setup script). All commands below assume you are in the
> repository root (`agentic-runtime-security-on-aws-agentcore/`).

## Step 1 — Deploy the agent on AgentCore Runtime

```bash
cd applications/stage0hello
agentcore deploy --yes
agentcore status    # expect: Runtime READY
agentcore invoke "Hello, confirm you are running"
```

> **Note:** The runtime can take up to 2 minutes after deploy to reach `READY`.
> If `agentcore status` or `agentcore invoke` fails, wait and retry.

The agent deploys via CDK (CodeZip), runs on Nova Pro (`us.amazon.nova-pro-v1:0`), and
has a workload identity (ARN visible in `agentcore status`).

## Step 2 — Stand up the managed Knowledge Base

```bash
cd ../stage1-kb
bash create-kb.sh
```

This creates a managed Bedrock KB with a fictional corpus (Meridian Freight Logistics)
in three API calls. Wait for ingestion to complete (~2-5 min).

## Step 3 — Generate the workshop keypair + deploy the mock OAuth server

Generate an RSA keypair for signing workshop JWTs. The mock server bundles both the
private key (for signing) and the JWKS (for verification), so all JWT validation
happens against YOUR keypair — no external dependency.

```bash
cd ../vault-standin
bash tools/keygen.sh

cd ../oauth-mock-server
bash deploy.sh
```

Note the **Function URL** from the deploy output. Set it as a variable:

```bash
MOCK_SERVER_URL="<paste Function URL from deploy output, no trailing slash>"
OIDC_DISCOVERY_URL="${MOCK_SERVER_URL}/.well-known/openid-configuration"
JWKS_URL="${MOCK_SERVER_URL}/jwks.json"
ISSUER="https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin"

# Verify discovery + JWKS:
curl -s "$OIDC_DISCOVERY_URL" | python3 -m json.tool
curl -s "$JWKS_URL" | python3 -m json.tool
```

## Step 4 — Deploy the Gateway + KB target

```bash
cd ../stage0hello
agentcore add gateway \
  --name workshop-gateway \
  --authorizer-type CUSTOM_JWT \
  --discovery-url "$OIDC_DISCOVERY_URL" \
  --allowed-audience vault-standin \
  --runtimes stage0hello
agentcore deploy --yes

cd ../gateway-kb-target
bash deploy.sh
```

The Gateway validates inbound JWTs via your mock server's OIDC discovery + JWKS, and
the KB target Lambda wraps `bedrock:Retrieve` with `GATEWAY_IAM_ROLE` outbound auth.

## Step 5 — Deploy Vault Enterprise

Before deploying, place your Vault Enterprise license file:

```bash
# Paste your .hclic license content into this file (gitignored):
vi infrastructure/modules/vault_server/vault.hclic
```

Then deploy:

```bash
cd ../../infrastructure/modules/vault_server
bash deploy-vault-dev.sh
```

Wait ~90 seconds for Vault to start, then set the Vault address:

```bash
VAULT_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vault-enterprise-dev" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region us-east-1)
export VAULT_ADDR="http://${VAULT_IP}:8200"
export VAULT_TOKEN="workshop-root-token"
echo "Vault: $VAULT_ADDR"
```

Configure JWT auth — Vault validates JWTs against your mock server's JWKS:

```bash
# Enable JWT auth method
# Note: if you see "path is already in use at jwt/" — that's fine,
# it means JWT auth was already enabled. Continue to the next command.
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/sys/auth/jwt" -d '{"type":"jwt"}'

# Configure JWKS (pointing at YOUR mock server, not GitHub)
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/auth/jwt/config" \
  -d "{\"jwks_url\":\"$JWKS_URL\",\"default_role\":\"uc1-agent\"}"

# Create the uc1-agent role
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/auth/jwt/role/uc1-agent" \
  -d '{"role_type":"jwt","bound_audiences":["vault-standin"],"bound_subject":"uc1-agent","user_claim":"sub","token_policies":["uc1"],"token_ttl":"15m"}'
```

## What you now have

- An agent on AgentCore Runtime with a workload identity
- A Knowledge Base (Meridian corpus) as the protected resource
- A self-hosted keypair + mock OAuth server (your JWKS, your keys)
- A Gateway that validates JWTs via your mock server's OIDC discovery
- Vault Enterprise validating JWTs against the same JWKS
- All JWT verification uses YOUR keypair — self-contained, no external dependencies

The following sections demonstrate how these components enforce the security
control objectives.
