---
title: 'Wire the OBO exchange + Vault login'
weight: 64
---

## The agent's job

The agent tool `retrieve_from_kb_as_user` performs four actions in sequence:

1. Extract the workload access token (WAT) from request context
2. Exchange the WAT for a user-scoped OBO token via AgentCore Identity
3. Present the OBO token to Vault's JWT auth backend
4. Use the Vault-vended STS credentials to query the Knowledge Base

Each step fails fast if the previous one returned an error.

## Agent code

Add this tool to your agent's `app.py` (or see the reference in
`applications/stage0hello/agentcore/app.py`):

```python
import urllib.request
import urllib.parse
import json
import os
import boto3
from agentcore import tool, Context
from bedrock_agentcore.identity import IdentityClient

VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://<VAULT_IP>:8200")
VAULT_JWT_ROLE = os.environ.get("VAULT_JWT_ROLE", "alice-user")
KB_ID = os.environ.get("KB_ID", "<YOUR_KB_ID>")
MODEL_ARN = os.environ.get(
    "MODEL_ARN",
    "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
)

@tool
def retrieve_from_kb_as_user(query: str, context: Context) -> str:
    """Answer a question using Vault-mediated, per-user credentials."""

    # 1. Get the workload access token
    wat = context.request_headers.get("workloadaccesstoken")
    if not wat:
        return "ERROR: No workload access token in request context."

    # 2. OBO exchange
    identity = IdentityClient("us-east-1")
    obo_response = identity.get_resource_oauth2_token(
        resource_credential_provider_name="workshop-obo-vault",
        oauth2_flow="ON_BEHALF_OF_TOKEN_EXCHANGE",
        scopes=["kb:read"],
        workload_identity_token=wat,
    )
    obo_token = obo_response.get("access_token") or obo_response["token"]["access_token"]

    # 3. Vault JWT login
    vault_payload = json.dumps({"jwt": obo_token, "role": VAULT_JWT_ROLE}).encode()
    vault_req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/auth/jwt/login",
        data=vault_payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(vault_req) as resp:
        vault_data = json.loads(resp.read())
    vault_token = vault_data["auth"]["client_token"]

    # 4. Read STS credentials from Vault
    sts_req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/aws/sts/bedrock-reader",
        headers={"X-Vault-Token": vault_token},
        method="POST",
    )
    with urllib.request.urlopen(sts_req) as resp:
        sts_data = json.loads(resp.read())
    creds = sts_data["data"]

    # 5. Query KB with vended credentials
    session = boto3.Session(
        aws_access_key_id=creds["access_key"],
        aws_secret_access_key=creds["secret_key"],
        aws_session_token=creds["security_token"],
        region_name="us-east-1",
    )
    kb_client = session.client("bedrock-agent-runtime")
    kb_resp = kb_client.retrieve_and_generate(
        input={"text": query},
        retrieveAndGenerateConfiguration={
            "type": "KNOWLEDGE_BASE",
            "knowledgeBaseConfiguration": {
                "knowledgeBaseId": KB_ID,
                "modelArn": MODEL_ARN,
            },
        },
    )
    return kb_resp["output"]["text"]
```

## Key implementation notes

**WAT extraction**: The runtime places the workload access token in
`context.request_headers['workloadaccesstoken']`. This is only present when the
inbound authorizer is configured (previous step).

**IdentityClient**: Part of the `bedrock-agentcore` SDK. The `workload_identity_token`
parameter is what makes this an OBO exchange rather than a client-credentials grant.

**urllib vs requests**: The AgentCore Lambda sandbox includes `urllib` (stdlib) but
not `requests`. All HTTP calls use `urllib.request`.

**VAULT_JWT_ROLE**: In this workshop each user maps to a specific Vault role
(`alice-user`, `bob-user`). In production you'd use a single role with
`bound_claims` matching user attributes.

## Environment variables

Set these in your agent's environment (via `agentcore.json` or `deploy.sh`):

| Variable | Value |
|----------|-------|
| `VAULT_ADDR` | `http://<VAULT_IP>:8200` |
| `VAULT_JWT_ROLE` | `alice-user` (or `bob-user` for testing denial) |
| `KB_ID` | Your Bedrock Knowledge Base ID |
| `MODEL_ARN` | Foundation model ARN for RetrieveAndGenerate |
