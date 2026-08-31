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

# Set the client secret for the mock OAuth server.
# This is used by AgentCore Identity when calling the /token endpoint.
# You can choose any value — just use the same one when registering the credential provider.
export CLIENT_SECRET="workshop-obo-secret-1"

bash deploy.sh
```

Set the mock server URL from the deployed API Gateway:

```bash
MOCK_SERVER_URL="https://$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='oauth-mock-api'].ApiId | [0]" \
  --output text).execute-api.${AWS_REGION:-us-east-1}.amazonaws.com"
OIDC_DISCOVERY_URL="${MOCK_SERVER_URL}/.well-known/openid-configuration"
JWKS_URL="${MOCK_SERVER_URL}/jwks.json"
# ISSUER must match the APIGW URL (OIDC spec requires issuer = discovery URL prefix)
ISSUER="${MOCK_SERVER_URL}"

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

```bash
cd ../../infrastructure/modules/vault_server

# Paste your Vault Enterprise license into this file (gitignored):
vim vault.hclic

bash deploy-vault-dev.sh
```

Wait ~90 seconds for Vault to start, then configure:

```bash
VAULT_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vault-enterprise-dev" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region us-east-1)
export VAULT_ADDR="http://${VAULT_IP}:8200"
export VAULT_TOKEN="workshop-root-token"

# If vault command is not found, re-run the setup script:
#   bash scripts/setup-cloudshell.sh

vault status    # expect: Sealed=false, Version=2.0.4+ent

# Enable JWT auth
# Note: if you see "path is already in use at jwt/" — that's fine, it means
# JWT auth was already enabled. Continue to the next command.
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/sys/auth/jwt" -d '{"type":"jwt"}'

# Point Vault at your mock server's JWKS
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/auth/jwt/config" \
  -d "{\"jwks_url\":\"$JWKS_URL\",\"default_role\":\"uc1-agent\"}"

# Create the uc1-agent role
curl -s -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/auth/jwt/role/uc1-agent" \
  -d '{"role_type":"jwt","bound_audiences":["vault-standin"],"bound_subject":"uc1-agent","user_claim":"sub","token_policies":["uc1"],"token_ttl":"15m"}'
```

### Configure Vault's AWS secrets engine

Vault needs an IAM user with static access keys (not session credentials) to call
`sts:AssumeRole` and vend scoped credentials. Create the IAM user, a scoped role,
and configure Vault:

```bash
cd ~/agentic-runtime-security-on-aws-agentcore
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 \
  --query "knowledgeBaseSummaries[?contains(name,'meridian')].knowledgeBaseId | [0]" --output text)

# Create IAM user for Vault's AWS secrets engine
aws iam create-user --user-name vault-aws-engine 2>/dev/null || true
aws iam put-user-policy --user-name vault-aws-engine --policy-name vault-sts \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"*"}]}'
aws iam create-access-key --user-name vault-aws-engine --output json > /tmp/vault-keys.json
VAULT_AWS_KEY=$(python3 -c "import json; d=json.load(open('/tmp/vault-keys.json')); print(d['AccessKey']['AccessKeyId'])")
VAULT_AWS_SECRET=$(python3 -c "import json; d=json.load(open('/tmp/vault-keys.json')); print(d['AccessKey']['SecretAccessKey'])")

# Create the scoped KB-read role that Vault will assume
aws iam create-role --role-name Stage2VendedKBReadRole \
  --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::${ACCOUNT}:user/vault-aws-engine\"},\"Action\":\"sts:AssumeRole\"}]}" 2>/dev/null || true
aws iam put-role-policy --role-name Stage2VendedKBReadRole --policy-name kb-read \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"bedrock:Retrieve\",\"Resource\":\"arn:aws:bedrock:us-east-1:${ACCOUNT}:knowledge-base/${KB_ID}\"}]}"

echo "Waiting 10s for IAM propagation..."
sleep 10

# Enable Vault AWS secrets engine
vault secrets enable aws 2>/dev/null || true
vault write aws/config/root \
  access_key="$VAULT_AWS_KEY" \
  secret_key="$VAULT_AWS_SECRET" \
  region=us-east-1

vault write aws/roles/bedrock-reader \
  role_arns="arn:aws:iam::${ACCOUNT}:role/Stage2VendedKBReadRole" \
  credential_type=assumed_role \
  default_sts_ttl=15m

# Create the uc1 policy (allows vending STS creds)
vault policy write uc1 - <<'EOF'
path "aws/sts/bedrock-reader" {
  capabilities = ["update"]
}
EOF
```

## What you now have

- An agent on AgentCore Runtime with a workload identity
- A Knowledge Base (Meridian corpus) as the protected resource
- A self-hosted keypair + mock OAuth server (your JWKS, your keys)
- A Gateway that validates JWTs via your mock server's OIDC discovery
- Vault Enterprise validating JWTs against the same JWKS
- Vault AWS secrets engine configured to vend scoped KB-read credentials
- All JWT verification uses YOUR keypair — self-contained, no external dependencies

The following sections demonstrate how these components enforce the security
control objectives.
