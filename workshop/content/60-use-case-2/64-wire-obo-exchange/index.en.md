---
title: 'Wire the OBO exchange + Vault login'
weight: 64
---

## The agent's job

The agent tool `retrieve_from_kb_as_user` performs four actions in sequence:

1. Exchange the workload access token for a user-scoped OBO token via AgentCore Identity
2. Present the OBO token to Vault's JWT auth backend
3. Use the Vault-vended STS credentials to query the Knowledge Base
4. Return the KB results attributed to the authenticated user

Each step fails fast if the previous one returned an error.

## Configure Vault for per-user authorization

Create per-user JWT roles and policies in Vault. Alice is allowed to vend KB
credentials; Bob is denied:

```bash
# Create per-user policies
vault policy write alice-kb - <<'EOF'
path "aws/sts/bedrock-reader" {
  capabilities = ["update"]
}
EOF

vault policy write bob-kb - <<'EOF'
path "aws/sts/bedrock-reader" {
  capabilities = ["deny"]
}
EOF

# Create per-user JWT roles (bound_subject must match the OBO token's sub claim)
vault write auth/jwt/role/alice-user \
  role_type=jwt \
  bound_audiences=vault-standin \
  bound_subject=alice@example.com \
  user_claim=sub \
  token_policies=alice-kb \
  token_ttl=15m

vault write auth/jwt/role/bob-user \
  role_type=jwt \
  bound_audiences=vault-standin \
  bound_subject=bob@example.com \
  user_claim=sub \
  token_policies=bob-kb \
  token_ttl=15m

# Verify
vault read auth/jwt/role/alice-user -format=json | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(f'alice-user: bound_subject={d[\"bound_subject\"]}, policies={d[\"token_policies\"]}')"
vault read auth/jwt/role/bob-user -format=json | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(f'bob-user: bound_subject={d[\"bound_subject\"]}, policies={d[\"token_policies\"]}')"
```

## Open Vault to AgentCore Runtime

AgentCore Runtime has `PUBLIC` network mode — its outbound calls come from
AWS-managed IPs, not your CloudShell IP. The Vault security group must allow
inbound on port 8200 from `0.0.0.0/0`:

```bash
SG_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vault-enterprise-dev" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text --region us-east-1)

aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --region us-east-1 \
  --ip-permissions "IpProtocol=tcp,FromPort=8200,ToPort=8200,IpRanges=[{CidrIp=0.0.0.0/0,Description=AgentCore-Runtime-egress}]" 2>/dev/null || true

echo "SG $SG_ID: port 8200 open to 0.0.0.0/0 (for AgentCore Runtime)"
```

> **Production note:** In production, use a VPC endpoint or private connectivity
> instead of `0.0.0.0/0`. For this workshop, the open rule is acceptable.

## Patch the agent code with your Vault IP

The agent code defaults `VAULT_ADDR` to a placeholder. Patch it with your Vault
instance's IP:

```bash
cd ~/agentic-runtime-security-on-aws-agentcore/applications/stage0hello

VAULT_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vault-enterprise-dev" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region us-east-1)

python3 -c "
import re
with open('app/stage0hello/main.py') as f:
    code = f.read()
code = re.sub(
    r'VAULT_ADDR = os\.getenv\(\"VAULT_ADDR\", \"http://[^\"]+\"\)',
    'VAULT_ADDR = os.getenv(\"VAULT_ADDR\", \"http://${VAULT_IP}:8200\")',
    code
)
with open('app/stage0hello/main.py', 'w') as f:
    f.write(code)
print('Patched VAULT_ADDR to http://${VAULT_IP}:8200')
"

# Verify
grep 'VAULT_ADDR =' app/stage0hello/main.py | head -1
```

## How the workload access token reaches the tool

AgentCore Runtime injects the WAT as a request header. The entrypoint captures it
into a module-level variable that the tool reads:

```python
# Module-level store (set in the entrypoint, read by tools)
_current_workload_access_token = None

@app.entrypoint
async def invoke(payload, context):
    global _current_workload_access_token
    _current_workload_access_token = None
    if hasattr(context, 'request_headers'):
        hdrs = context.request_headers or {}
        for key in ['workloadaccesstoken', 'x-amz-bedrock-agentcore-identity-wat']:
            if hdrs.get(key):
                _current_workload_access_token = hdrs[key]
                break
    # ... rest of entrypoint
```

## Implementation notes

- **No `context` parameter on the tool.** Strands tools receive only their declared
  parameters. The WAT is stored in a module-level variable by the entrypoint.
- **`obo_response["accessToken"]`** is camelCase (the SDK returns the raw API response).
- **`client.retrieve()`** not `retrieve_and_generate()`. We want raw passages, not
  model-generated answers.
- **`urllib.request`** for Vault HTTP calls. No `hvac` dependency needed.
- **STS TTL must be >= 15m.** AWS STS requires a minimum DurationSeconds of 900.

## Deploy

Deploy first, then re-grant the execution role permissions:

```bash
agentcore deploy --yes

EXECUTION_ROLE_NAME=$(aws iam list-roles \
  --query "Roles[?starts_with(RoleName,'AgentCore-stage0hello') && contains(RoleName,'Application')].RoleName | [0]" \
  --output text)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 \
  --query "knowledgeBaseSummaries[?contains(name,'meridian')].knowledgeBaseId | [0]" --output text)
SECRET_ARN=$(aws bedrock-agentcore-control get-oauth2-credential-provider \
  --name workshop-obo-vault --region us-east-1 \
  --query 'clientSecretArn.secretArn' --output text)

aws iam put-role-policy --role-name "$EXECUTION_ROLE_NAME" --policy-name kb-read \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"bedrock:Retrieve\",\"Resource\":\"arn:aws:bedrock:us-east-1:${ACCOUNT}:knowledge-base/${KB_ID}\"}]}"
aws iam put-role-policy --role-name "$EXECUTION_ROLE_NAME" --policy-name obo-identity \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock-agentcore:GetResourceOauth2Token","bedrock-agentcore:GetWorkloadAccessToken","bedrock-agentcore:GetWorkloadAccessTokenForJWT","bedrock-agentcore:GetWorkloadAccessTokenForUserId"],"Resource":"*"}]}'
aws iam put-role-policy --role-name "$EXECUTION_ROLE_NAME" --policy-name obo-secrets \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"${SECRET_ARN}\"}]}"

echo "Policies re-applied to $EXECUTION_ROLE_NAME"
```

> ⚠️ **Why re-apply after deploy?** `agentcore deploy` uses CDK under the hood,
> which replaces the execution role's inline policies with its own managed defaults.
> Any manually-added policies (`kb-read`, `obo-identity`, `obo-secrets`) are stripped
> during the deploy. That's why we re-apply them **after** every `agentcore deploy`,
> not before.
