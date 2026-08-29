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

## Agent code

The full tool lives in `applications/stage0hello/app/stage0hello/main.py`. Here is
the core logic:

```python
import urllib.request
import json
import base64
import os
import boto3
from bedrock_agentcore.services.identity import IdentityClient
from strands import Agent, tool

OBO_PROVIDER_NAME = os.getenv("OBO_PROVIDER_NAME", "workshop-obo-vault")
VAULT_ADDR = os.getenv("VAULT_ADDR", "http://<VAULT_IP>:8200")
VAULT_JWT_ROLE = os.getenv("VAULT_JWT_ROLE", "alice-user")
VAULT_STS_ROLE = os.getenv("VAULT_STS_ROLE", "bedrock-reader")
VAULT_STS_TTL = os.getenv("VAULT_STS_TTL", "15m")
BEDROCK_KB_ID = os.getenv("BEDROCK_KB_ID", "<YOUR_KB_ID>")

@tool
def retrieve_from_kb_as_user(query: str) -> list:
    """Retrieve from KB using per-user Vault-vended credentials."""

    global _current_workload_access_token
    if not _current_workload_access_token:
        return [{"error": "No workload access token available."}]

    # Step 1: OBO exchange
    identity_client = IdentityClient("us-east-1")
    obo_response = identity_client.get_resource_oauth2_token(
        resource_credential_provider_name=OBO_PROVIDER_NAME,
        oauth2_flow="ON_BEHALF_OF_TOKEN_EXCHANGE",
        scopes=["kb:read"],
        workload_identity_token=_current_workload_access_token,
    )
    obo_token = obo_response["accessToken"]

    # Decode user identity from the OBO token
    parts = obo_token.split(".")
    payload_b64 = parts[1] + "=" * (4 - len(parts[1]) % 4)
    user_claims = json.loads(base64.b64decode(payload_b64))
    username = user_claims.get("sub", "unknown")

    # Step 2: Vault JWT login
    vault_payload = json.dumps({"role": VAULT_JWT_ROLE, "jwt": obo_token}).encode()
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/auth/jwt/login",
        data=vault_payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        vault_data = json.loads(resp.read())
    vault_token = vault_data["auth"]["client_token"]

    # Step 3: Vault STS credentials
    sts_payload = json.dumps({"ttl": VAULT_STS_TTL}).encode()
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/aws/sts/{VAULT_STS_ROLE}",
        data=sts_payload,
        headers={"Content-Type": "application/json", "X-Vault-Token": vault_token},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        sts_data = json.loads(resp.read())
    creds = sts_data["data"]

    # Step 4: Query KB with user-scoped credentials
    kb_client = boto3.client(
        "bedrock-agent-runtime",
        aws_access_key_id=creds["access_key"],
        aws_secret_access_key=creds["secret_key"],
        aws_session_token=creds["security_token"],
        region_name="us-east-1",
    )
    kb_resp = kb_client.retrieve(
        knowledgeBaseId=BEDROCK_KB_ID,
        retrievalQuery={"text": query},
    )
    return [
        {"text": r.get("content", {}).get("text", ""), "score": r.get("score"), "user": username}
        for r in kb_resp.get("retrievalResults", [])
    ]
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

```bash
cd applications/stage0hello
AWS_PROFILE=agenticvault agentcore deploy
```
