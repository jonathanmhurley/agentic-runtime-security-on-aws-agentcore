"""AgentCore workshop agent — Strands on Amazon Bedrock AgentCore Runtime (UC2).

A read-only knowledge assistant that retrieves from a managed Bedrock Knowledge
Base. The agent's execution role (or Gateway's outbound GATEWAY_IAM_ROLE) holds
the scoped bedrock:Retrieve credential — the agent never holds standing access.

This is the proven workshop agent: Stages 0-1 (hello-world, KB read via scoped
exec role), Gateway proof, and UC2 (OBO + Vault per-user authorization).


UC2 addition: On-Behalf-Of (OBO) token exchange — the agent retrieves a
downstream-scoped token carrying the authenticated user's identity.
"""

import os

import boto3
from bedrock_agentcore.services.identity import IdentityClient
from strands import Agent, tool
from strands.agent.conversation_manager.null_conversation_manager import NullConversationManager
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from model.load import load_model
from mcp_client.client import get_streamable_http_mcp_client

app = BedrockAgentCoreApp()
log = app.logger

# MCP client — connects to Gateway-exposed tools when configured
mcp_clients = [get_streamable_http_mcp_client()]

# --- OBO credential provider name (registered in Phase B) --------------------
OBO_PROVIDER_NAME = os.getenv("OBO_PROVIDER_NAME", "workshop-obo-vault")

# --- Vault configuration (Phase D) -------------------------------------------
VAULT_ADDR = os.getenv("VAULT_ADDR", "http://<VAULT_IP>:8200")
VAULT_JWT_ROLE = os.getenv("VAULT_JWT_ROLE", "alice-user")  # default for testing; production would resolve per-user
VAULT_STS_ROLE = os.getenv("VAULT_STS_ROLE", "bedrock-reader")
VAULT_STS_TTL = os.getenv("VAULT_STS_TTL", "15m")

# Workload name must match the runtime's workload identity name
WORKLOAD_NAME = os.getenv("WORKLOAD_NAME", "stage0hello_stage0hello")

# Module-level store for the workload access token (set in entrypoint from context)
_current_workload_access_token = None


SYSTEM_PROMPT = """
You are a read-only knowledge assistant. When asked a question, use the
retrieve_from_kb_as_user tool if available — it authenticates to Vault on
behalf of the current user and reads the Knowledge Base with per-user scoped
credentials. If retrieve_from_kb_as_user is not available or not listed in
your tools, use retrieve_from_kb instead.

If the user asks who they are or about their identity, use the
get_user_identity tool to retrieve the authenticated user's identity from
the OBO token exchange.
"""

# --- Knowledge Base retrieval ------------------------------------------------
# The KB ID is a workshop resource identifier (not a secret). Falls back to the
# known Stage 1 Meridian KB since this CLI version does not inject agentcore.json
# environmentVariables onto the runtime.
def _discover_kb_id():
    """Auto-discover the Meridian KB ID, falling back to env var or hardcoded default."""
    kb_id = os.getenv("BEDROCK_KB_ID")
    if kb_id:
        return kb_id
    # Auto-discover from list-knowledge-bases (matches the Meridian KB name)
    try:
        import boto3 as _boto3
        client = _boto3.client("bedrock-agent")
        resp = client.list_knowledge_bases()
        for kb in resp.get("knowledgeBaseSummaries", []):
            if "meridian" in kb.get("name", "").lower():
                return kb["knowledgeBaseId"]
    except Exception:
        pass
    return "QLKOTZM2GC"  # fallback to dev account KB

BEDROCK_KB_ID = _discover_kb_id()


@tool
def retrieve_from_kb(query: str) -> list:
    """Retrieve relevant passages from the Bedrock Knowledge Base.

    Args:
        query: The natural-language question to search the knowledge base for.

    Returns:
        A list of {text, score, location} passages.
    """
    if not BEDROCK_KB_ID:
        return [{"text": "BEDROCK_KB_ID is not set.", "score": None, "location": None}]
    client = boto3.client("bedrock-agent-runtime")
    resp = client.retrieve(
        knowledgeBaseId=BEDROCK_KB_ID,
        retrievalQuery={"text": query},
    )
    return [
        {
            "text": r.get("content", {}).get("text", ""),
            "score": r.get("score"),
            "location": r.get("location"),
        }
        for r in resp.get("retrievalResults", [])
    ]


# --- UC2: OBO token exchange -------------------------------------------------
# Manual IdentityClient approach:
# 1. Get workload access token (Runtime auto-injects this, but for local
#    testing we call get_workload_access_token_for_jwt manually)
# 2. Call get_resource_oauth2_token with ON_BEHALF_OF_TOKEN_EXCHANGE
# 3. Decode the returned OBO token to extract user identity

@tool
def get_user_identity() -> dict:
    """Retrieve the authenticated user's identity via OBO token exchange.

    Returns the user identity claims from the downstream OBO token,
    proving that user context propagates through the agent. No arguments
    needed — the identity is extracted from the runtime's auth context.
    """
    import json as _json
    import base64 as _b64

    global _current_workload_access_token
    if not _current_workload_access_token:
        return {"error": "No workload access token available — is the runtime configured with JWT inbound auth?"}

    identity_client = IdentityClient("us-east-1")

    obo_response = identity_client.get_resource_oauth2_token(
        resource_credential_provider_name=OBO_PROVIDER_NAME,
        oauth2_flow="ON_BEHALF_OF_TOKEN_EXCHANGE",
        scopes=["kb:read"],
        workload_identity_token=_current_workload_access_token,
    )
    access_token = obo_response["accessToken"]

    # Decode the JWT payload (no signature verification — we trust our own mock)
    parts = access_token.split(".")
    payload_b64 = parts[1] + "=" * (4 - len(parts[1]) % 4)  # pad
    claims = _json.loads(_b64.b64decode(payload_b64))
    return {
        "user": claims.get("sub", "unknown"),
        "scope": claims.get("scope", ""),
        "actor": claims.get("act", {}),
        "issuer": claims.get("iss", ""),
    }


# --- UC2 Phase D: Full Vault-mediated KB read --------------------------------
# OBO token → Vault login → STS creds → KB retrieve (all per-user)

@tool
def retrieve_from_kb_as_user(query: str) -> list:
    """Retrieve from the Knowledge Base using per-user Vault-vended credentials.

    This is the UC2 secure path: the agent authenticates to Vault on behalf of
    the current user (via the OBO token), Vault applies per-user policies, and
    vends short-lived STS credentials scoped to KB read. The agent then queries
    the KB with those user-specific credentials.

    Args:
        query: The natural-language question to search the knowledge base for.

    Returns:
        A list of {text, score, user} passages (user = authenticated identity).
    """
    import json as _json
    import base64 as _b64
    import urllib.request

    global _current_workload_access_token
    if not _current_workload_access_token:
        return [{"error": "No workload access token — runtime not configured with JWT inbound auth."}]

    # Step 1: Get OBO token (user identity)
    identity_client = IdentityClient("us-east-1")
    obo_response = identity_client.get_resource_oauth2_token(
        resource_credential_provider_name=OBO_PROVIDER_NAME,
        oauth2_flow="ON_BEHALF_OF_TOKEN_EXCHANGE",
        scopes=["kb:read"],
        workload_identity_token=_current_workload_access_token,
    )
    obo_token = obo_response["accessToken"]

    # Decode user from OBO token
    parts = obo_token.split(".")
    payload_b64 = parts[1] + "=" * (4 - len(parts[1]) % 4)
    user_claims = _json.loads(_b64.b64decode(payload_b64))
    username = user_claims.get("sub", "unknown")
    log.info(f"UC2: Authenticated as {username}, presenting to Vault")

    # Step 2: Vault JWT login
    vault_login_payload = _json.dumps({"role": VAULT_JWT_ROLE, "jwt": obo_token}).encode()
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/auth/jwt/login",
        data=vault_login_payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        vault_login_resp = _json.loads(resp.read())
    vault_token = vault_login_resp["auth"]["client_token"]
    log.info(f"UC2: Vault login successful for {username}, policies: {vault_login_resp['auth']['policies']}")

    # Step 3: Vault STS creds
    sts_payload = _json.dumps({"ttl": VAULT_STS_TTL}).encode()
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/aws/sts/{VAULT_STS_ROLE}",
        data=sts_payload,
        headers={"Content-Type": "application/json", "X-Vault-Token": vault_token},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        sts_resp = _json.loads(resp.read())
    creds = sts_resp["data"]
    log.info(f"UC2: Vault vended STS creds for {username} (arn: {creds.get('arn', 'N/A')})")

    # Step 4: KB retrieve with user-scoped creds
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
        {
            "text": r.get("content", {}).get("text", ""),
            "score": r.get("score"),
            "user": username,
        }
        for r in kb_resp.get("retrievalResults", [])
    ]


# --- Agent setup -------------------------------------------------------------
# When OBO is configured (UC2), only expose retrieve_from_kb_as_user so that
# denied users (e.g. Bob) cannot fall back to the unscoped retrieve_from_kb.
# When OBO is NOT configured (UC1 / Stage 1), only expose retrieve_from_kb.
# Signal: VAULT_ADDR is set (either via env var or hardcoded to a real IP).
_vault_addr = os.getenv("VAULT_ADDR", VAULT_ADDR)
_obo_configured = _vault_addr and "placeholder" not in _vault_addr.lower() and "<" not in _vault_addr

if _obo_configured:
    tools = [get_user_identity, retrieve_from_kb_as_user]
else:
    tools = [retrieve_from_kb]

for mcp_client in mcp_clients:
    if mcp_client:
        tools.append(mcp_client)

_agent = None


def get_or_create_agent():
    global _agent
    if _agent is None:
        _agent = Agent(
            model=load_model(),
            system_prompt=SYSTEM_PROMPT,
            tools=tools,
            conversation_manager=NullConversationManager(),
        )
    return _agent


# --- Entrypoint --------------------------------------------------------------

def _extract_prompt(payload: dict):
    """Accept harness-style messages[], tool_results[], or plain prompt string."""
    if "messages" in payload:
        return payload["messages"]
    if "tool_results" in payload:
        return [{"role": "user", "content": [{"toolResult": {
            "toolUseId": tr["toolUseId"],
            "status": tr.get("status", "success"),
            "content": tr.get("content", []),
        }} for tr in payload["tool_results"]]}]
    return payload.get("prompt", "")


@app.entrypoint
async def invoke(payload, context):
    global _current_workload_access_token
    log.info("Invoking agent")

    # Extract workload access token from runtime context headers
    _current_workload_access_token = None
    if hasattr(context, 'request_headers'):
        hdrs = context.request_headers or {}
        for key in ['workloadaccesstoken', 'x-amz-bedrock-agentcore-identity-wat']:
            if hdrs.get(key):
                _current_workload_access_token = hdrs[key]
                break
    log.info(f"Workload access token present: {bool(_current_workload_access_token)}")

    agent = get_or_create_agent()
    prompt = _extract_prompt(payload)

    async for event in agent.stream_async(prompt):
        if not isinstance(event, dict) or "event" not in event:
            continue
        cbs = event["event"].get("contentBlockStart")
        if cbs is not None and not cbs.get("start"):
            continue
        yield event


if __name__ == "__main__":
    app.run()
