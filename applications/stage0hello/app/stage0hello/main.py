from typing import Any
import os
import boto3
from strands import Agent, tool
import asyncio
from strands.agent.conversation_manager.null_conversation_manager import NullConversationManager
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from model.load import load_model
from mcp_client.client import get_streamable_http_mcp_client

app = BedrockAgentCoreApp()
log = app.logger

# Define a Streamable HTTP MCP Client
mcp_clients = [get_streamable_http_mcp_client()]

DEFAULT_SYSTEM_PROMPT = """
You are a read-only knowledge assistant. When asked a question, use the
retrieve_from_kb tool to fetch supporting passages from the knowledge base and
answer strictly from what it returns. You have no user context and cannot write.
When the caller provides a JWT or asks to use the broker, use
retrieve_from_kb_via_broker instead (it obtains scoped credentials from the
credential broker before reading the knowledge base).
"""


# Define a collection of tools used by the model
tools = []

_INLINE_FUNCTION_NAMES = set()

# Define a simple function tool
@tool
def add_numbers(a: int, b: int) -> int:
    """Return the sum of two numbers"""
    return a+b
tools.append(add_numbers)


# --- Stage 1: Bedrock Knowledge Base retrieval -------------------------------
# Proves OBJ-1 (agent workload identity) + the KB read path. The agent's
# AgentCore Runtime EXECUTION ROLE is the scoped credential here — it is granted
# bedrock:Retrieve on exactly one KB (out-of-band, see docs/STAGES.md Stage 1).
# This role is the first "Vault stand-in": a scoped, least-privilege credential
# the agent uses to reach a protected resource. In Stage 3 the same read is
# brokered by Vault-vended dynamic creds instead.
# KB id resolves from env first (set via agentcore.json environmentVariables or
# `agentcore deploy --env`); falls back to the known Stage 1 KB so the agent
# works even if the CLI env-var wiring does not inject it. Not a secret — a
# workshop resource id.
_DEFAULT_KB_ID = "QLKOTZM2GC"  # stage1-meridian-kb (managed KB, us-east-1)
BEDROCK_KB_ID = os.getenv("BEDROCK_KB_ID") or _DEFAULT_KB_ID

@tool
def retrieve_from_kb(query: str) -> list:
    """Retrieve relevant passages from the Bedrock Knowledge Base.

    Args:
        query: The natural-language question to search the knowledge base for.

    Returns:
        A list of {text, score, location} passages. Empty list if BEDROCK_KB_ID
        is unset (so the agent degrades gracefully rather than erroring).
    """
    if not BEDROCK_KB_ID:
        return [{"text": "BEDROCK_KB_ID is not set; no knowledge base configured.", "score": None, "location": None}]
    # boto3 picks up the AgentCore-injected execution-role credentials from the env.
    client = boto3.client("bedrock-agent-runtime")
    resp = client.retrieve(
        knowledgeBaseId=BEDROCK_KB_ID,
        retrievalQuery={"text": query},
    )
    results = []
    for r in resp.get("retrievalResults", []):
        results.append({
            "text": r.get("content", {}).get("text", ""),
            "score": r.get("score"),
            "location": r.get("location"),
        })
    return results
tools.append(retrieve_from_kb)


# --- Stage 2: retrieve via the credential-broker (Vault stand-in) -------------
# This is the SAME KB read as Stage 1, but the credential is obtained by
# presenting a JWT to the broker Lambda, which validates it (JWKS), checks an
# allowlist (Agent Registry stand-in), and vends short-lived STS creds (dynamic
# secrets stand-in). In Stage 3 the broker URL is replaced by Vault's endpoint
# and the agent tool code does not change.
#
# Config (env first, code fallback since this CLI does not inject agentcore.json
# env vars onto the runtime):
_DEFAULT_BROKER_URL = "https://w4tbhstko3rrnqa7rmxbbrhegu0grdxz.lambda-url.us-east-1.on.aws/"
BROKER_URL = os.getenv("BROKER_URL") or _DEFAULT_BROKER_URL
# The workshop JWT is provided at invoke time in the payload; a fallback env var
# allows a pre-minted token for smoke tests. Never hardcode a real token.
AGENT_JWT = os.getenv("AGENT_JWT", "")
# Holds the JWT supplied in the current invoke payload (set by the entrypoint).
_REQUEST_JWT = {"token": ""}
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")


# Broker Lambda function name (direct lambda.invoke transport — see below).
_DEFAULT_BROKER_FUNCTION = "stage2-cred-broker"
BROKER_FUNCTION = os.getenv("BROKER_FUNCTION") or _DEFAULT_BROKER_FUNCTION


def _broker_vend(jwt_token: str) -> dict:
    """Exchange the JWT for short-lived scoped credentials via a DIRECT
    lambda.invoke on the broker function (not a Function URL).

    Why direct invoke: the agent already runs with an IAM execution role, and the
    AgentCore runtime signs AWS API calls natively (Bedrock/STS work). A Lambda
    Function URL added a separate HTTP-auth layer the runtime's outbound call did
    not satisfy (403 before the function ran). lambda.invoke is a standard signed
    AWS API call the runtime handles, so transport auth = IAM (execution role has
    lambda:InvokeFunction) and business auth = the JWT (broker validates via JWKS +
    allowlist). Real Vault (Stage 3) restores the HTTP-endpoint shape.
    """
    import json as _json
    import boto3 as _boto3

    client = _boto3.client("lambda", region_name=AWS_REGION)
    resp = client.invoke(
        FunctionName=BROKER_FUNCTION,
        Payload=_json.dumps({"jwt": jwt_token}).encode(),
    )
    raw = resp["Payload"].read()
    envelope = _json.loads(raw)  # handler returns {"statusCode", "body"}
    status = envelope.get("statusCode", 500)
    body = _json.loads(envelope.get("body", "{}"))
    if status != 200:
        raise RuntimeError(f"broker denied ({status}): {body.get('error', body)}")
    return body


@tool
def retrieve_from_kb_via_broker(query: str, jwt: str = "") -> list:
    """Retrieve from the KB using credentials VENDED BY THE BROKER (Stage 2 path).

    Presents a workshop JWT to the credential broker, receives short-lived scoped
    creds, and uses THOSE creds (not the execution role) to call bedrock:Retrieve.
    Demonstrates the full Vault-shaped flow: JWT -> validate -> vend -> use.

    Args:
        query: The question to search the knowledge base for.
        jwt: The workshop JWT. Falls back to the AGENT_JWT env var if omitted.

    Returns:
        A list of {text, score, location} passages, or a single error record.
    """
    token = jwt or _REQUEST_JWT.get("token") or AGENT_JWT
    if not token:
        return [{"text": "No JWT provided; pass jwt=... or set AGENT_JWT.", "score": None, "location": None}]
    try:
        vended = _broker_vend(token)
    except Exception as e:  # noqa: BLE001 — surface broker deny/validation errors to the model
        return [{"text": f"Broker denied or errored: {e}", "score": None, "location": None}]

    # Use the VENDED creds (not the execution role) for the KB call.
    import boto3 as _boto3
    client = _boto3.client(
        "bedrock-agent-runtime",
        aws_access_key_id=vended["access_key_id"],
        aws_secret_access_key=vended["secret_access_key"],
        aws_session_token=vended["session_token"],
        region_name=AWS_REGION,
    )
    resp = client.retrieve(knowledgeBaseId=BEDROCK_KB_ID, retrievalQuery={"text": query})
    results = []
    for r in resp.get("retrievalResults", []):
        results.append({
            "text": r.get("content", {}).get("text", ""),
            "score": r.get("score"),
            "location": r.get("location"),
        })
    return results
tools.append(retrieve_from_kb_via_broker)



# Add MCP client to tools if available
for mcp_client in mcp_clients:
    if mcp_client:
        tools.append(mcp_client)


def _make_conversation_manager():
    return NullConversationManager()

_agent = None

def get_or_create_agent():
    global _agent
    if _agent is None:
        _agent = Agent(
            model=load_model(),
            system_prompt=DEFAULT_SYSTEM_PROMPT,
            tools=tools,
            conversation_manager=_make_conversation_manager(),
            hooks=[
            ],
        )
    return _agent


def _extract_prompt(payload: dict):
    """Accept harness-style messages[], tool_results[], or plain prompt string payloads."""
    if "messages" in payload:
        return payload["messages"]
    if "tool_results" in payload:
        return [{"role": "user", "content": [{"toolResult": {
            "toolUseId": tr["toolUseId"],
            "status": tr.get("status", "success"),
            "content": tr.get("content", []),
        }} for tr in payload["tool_results"]]}]
    return payload.get("prompt", "")


def _has_inline_function_call(messages) -> bool:
    """Return True if messages contains an assistant toolUse for an inline function tool."""
    if not _INLINE_FUNCTION_NAMES or not isinstance(messages, list):
        return False
    for msg in messages:
        if msg.get("role") == "assistant":
            for block in msg.get("content", []):
                if isinstance(block, dict) and block.get("toolUse", {}).get("name") in _INLINE_FUNCTION_NAMES:
                    return True
    return False


def _is_inline_function_call(event: dict) -> bool:
    """Check if a contentBlockStart event is for an inline function tool."""
    if not _INLINE_FUNCTION_NAMES:
        return False
    cbs = event.get("contentBlockStart", {})
    start = cbs.get("start", {})
    tool_use = start.get("toolUse") if isinstance(start, dict) else None
    return tool_use is not None and tool_use.get("name") in _INLINE_FUNCTION_NAMES



@app.entrypoint
async def invoke(payload, context):
    log.info("Invoking Agent.....")


    agent = get_or_create_agent()

    # Capture a JWT supplied in the invoke payload so the broker-backed tool
    # can use it (this CLI does not inject env vars onto the runtime).
    if isinstance(payload, dict) and payload.get("jwt"):
        _REQUEST_JWT["token"] = payload["jwt"]

    prompt = _extract_prompt(payload)


    async for event in agent.stream_async(
        prompt,
    ):
        if not isinstance(event, dict) or "event" not in event:
            continue
        cbs = event["event"].get("contentBlockStart")
        if cbs is not None and not cbs.get("start"):
            continue
        yield event


if __name__ == "__main__":
    app.run()
