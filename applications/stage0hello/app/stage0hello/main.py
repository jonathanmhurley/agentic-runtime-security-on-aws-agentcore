"""AgentCore workshop agent — Strands on Amazon Bedrock AgentCore Runtime.

A read-only knowledge assistant that retrieves from a managed Bedrock Knowledge
Base. The agent's execution role (or Gateway's outbound GATEWAY_IAM_ROLE) holds
the scoped bedrock:Retrieve credential — the agent never holds standing access.

This is the proven workshop agent: Stage 0 (hello-world), Stage 1 (KB read via
scoped exec role), and Gateway proof (native AgentCore Gateway with JWT inbound
auth + scoped outbound creds) all run on this code.
"""

import os

import boto3
from strands import Agent, tool
from strands.agent.conversation_manager.null_conversation_manager import NullConversationManager
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from model.load import load_model
from mcp_client.client import get_streamable_http_mcp_client

app = BedrockAgentCoreApp()
log = app.logger

# MCP client — connects to Gateway-exposed tools when configured
mcp_clients = [get_streamable_http_mcp_client()]

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


# --- Agent setup -------------------------------------------------------------
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
    log.info("Invoking agent")
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
