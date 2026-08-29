---
title: 'Deploy the foundation'
weight: 30
---

## What you'll deploy

Three components that form the foundation for the workshop's security demonstrations:

1. **AgentCore Runtime agent** (Strands, Nova Pro) — the AI agent with a verifiable
   workload identity
2. **A managed Bedrock Knowledge Base** — the protected resource the agent reads from
3. **An AgentCore Gateway** — validates inbound JWTs and brokers scoped access to
   downstream targets

> **Before you start:** complete the [Prerequisites](../20-prerequisites/) section
> (clone the repo, run the setup script). All commands below assume you are in the
> repository root (`agentic-runtime-security-on-aws-agentcore/`).

## Workshop variables

Set these once. They're used across all steps:

```bash
# OIDC discovery + JWKS (public GitHub-hosted, same for all attendees)
OIDC_DISCOVERY_URL="https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin/.well-known/openid-configuration"
JWKS_URL="https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin/jwks.json"

# Account (auto-detected)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID"
```

## Step 1 — Deploy the agent on AgentCore Runtime

```bash
cd applications/stage0hello
agentcore deploy --yes
agentcore status    # expect: Runtime READY
agentcore invoke "Hello, confirm you are running"
```

> **First deploy note:** The runtime takes ~2 minutes after deploy to reach `READY`.
> If `agentcore status` or `agentcore invoke` fails immediately after deploy, wait
> a couple of minutes and retry.

The agent deploys via CDK (CodeZip), runs on Nova Pro (`us.amazon.nova-pro-v1:0`), and
has a workload identity (ARN visible in `agentcore status`).

## Step 2 — Stand up the managed Knowledge Base

```bash
cd ../stage1-kb
bash create-kb.sh
```

This creates a managed Bedrock KB with a fictional corpus (Meridian Freight Logistics)
in three API calls. Wait for ingestion to complete (~2-5 min).

## Step 3 — Deploy the Gateway + KB target

The Gateway already exists (defined in `agentcore.json`). Add the OIDC discovery
configuration, then deploy the KB target Lambda:

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

The Gateway validates inbound JWTs via OIDC discovery + JWKS, and the KB target Lambda
wraps `bedrock:Retrieve` with `GATEWAY_IAM_ROLE` outbound auth.

## Step 4 — Deploy Vault Enterprise

```bash
cd ../../infrastructure/modules/vault_server
bash deploy-vault-dev.sh
```

Wait ~90 seconds for Vault to start, then configure JWT auth:

```bash
export VAULT_ADDR="http://$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vault-workshop" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region us-east-1):8200"
export VAULT_TOKEN=workshop-root-token

vault auth enable jwt
vault write auth/jwt/config jwks_url="$JWKS_URL" default_role="uc1-agent"
vault write auth/jwt/role/uc1-agent \
  role_type=jwt bound_audiences=vault-standin bound_subject=uc1-agent \
  user_claim=sub token_policies=uc1 token_ttl=15m
```

See `docs/RUNBOOK.md` Stage 3 for the full Vault configuration commands.

## What you now have

- An agent on AgentCore Runtime with a workload identity
- A Knowledge Base (Meridian corpus) as the protected resource
- A Gateway that validates JWTs and brokers scoped access
- Vault Enterprise validating JWTs and vending dynamic credentials
- A local RS256 keypair + OIDC discovery for minting workshop tokens

The following sections demonstrate how these components enforce the five security
control objectives.
