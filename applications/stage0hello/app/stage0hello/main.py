"""AgentCore workshop agent — Strands on Amazon Bedrock AgentCore Runtime (UC2).

A read-only knowledge assistant that retrieves from a managed Bedrock Knowledge
Base. The agent's execution role (or Gateway's outbound GATEWAY_IAM_ROLE) holds
the scoped bedrock:Retrieve credential — the agent never holds standing access.

This is the proven workshop agent: Stage 0 (hello-world), Stage 1 (KB read via
scoped exec role), and Gateway proof (native AgentCore Gateway with JWT inbound

If the user asks who they are or about their identity, use the
get_user_identity tool to retrieve the authenticated user's identity from
the OBO token exchange.


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

# Workload name must match the runtime's workload identity name
WORKLOAD_NAME = os.getenv("WORKLOAD_NAME", "stage0hello_stage0hello")

# Module-level store for the workload access token (set in entrypoint from context)
_current_workload_access_token = None


SYSTEM_PROMPT = """
You are a read-only knowledge assistant. When asked a question, use the
retrieve_from_kb tool to fetch supporting passages from the knowledge base
and answer strictly from what it returns. You have no user context and cannot
perform writes.
"""

# --- Knowledge Base retrieval ------------------------------------------------
# The KB ID is a workshop resource identifier (not a secret). Falls back to the
# known Stage 1 Meridian KB since this CLI version does not inject agentcore.json
# environmentVariables onto the runtime.
_DEFAULT_KB_ID = "QLKOTZM2GC"  # stage1-meridian-kb (managed KB, us-east-1)
BEDROCK_KB_ID = os.getenv("BEDROCK_KB_ID") or _DEFAULT_KB_ID


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


# --- Agent setup -------------------------------------------------------------
tools = [retrieve_from_kb, get_user_identity]

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

    # DEBUG: log context structure to find workload access token location
    log.info(f"Context type: {type(context).__name__}")
    log.info(f"Context dir: {[a for a in dir(context) if not a.startswith('_')]}")
    if hasattr(context, '__dict__'):
        log.info(f"Context __dict__ keys: {list(context.__dict__.keys())}")
    if isinstance(context, dict):
        log.info(f"Context keys: {list(context.keys())}")

    # Try to extract workload access token from context
    _current_workload_access_token = None
    if hasattr(context, 'workload_access_token'):
        _current_workload_access_token = context.workload_access_token
    elif hasattr(context, 'request_headers'):
        hdrs = context.request_headers if isinstance(context.request_headers, dict) else {}
        log.info(f"Context headers keys: {list(hdrs.keys())}")
        for key in ['workloadaccesstoken', 'x-amz-bedrock-agentcore-identity-wat']:
            if hdrs.get(key):
                log.info(f"Found WAT candidate in header: {key} (len={len(hdrs[key])})")
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
