"""agent.py — UC1 Strands agent on AgentCore Runtime.

Non-personalized, read-only. Establishes the agent-identity + JIT-credential
backbone before any user context is introduced (that arrives in UC2 via OBO).

Security objectives demonstrated:
  OBJ-1: Verifiable agent identity — the agent presents its AgentCore
         workload-identity JWT, which Vault validates via the AgentCore JWKS
         endpoint (OAuth resource server profile "agentcore"). No Vault login,
         no static token, no Kubernetes auth.
  OBJ-2: No standing privileges — every credential (DB read role, Bedrock STS)
         is JIT, TTL-bound, and auto-revoked at lease expiry.
  OBJ-4: Enforcement at the point of use — Vault authorizes at credential-issue
         time based on the agent identity + Agent Registry registration.

Tools:
  query_knowledge_base — retrieve from the Bedrock Knowledge Base and answer.

There is deliberately NO user login, OAuth, PKCE, or OBO here — UC1 is the
"hello world" of the trust model: agent identity -> Vault JWT auth -> JIT read
credential -> Bedrock KB.
"""

import logging
import os

from strands import Agent, tool
from strands.models import BedrockModel

from .vault_client import UC1VaultClient

logger = logging.getLogger(__name__)

# Module-level Vault client (set by build_uc1_agent)
_vault_client: "UC1VaultClient | None" = None

BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0")
KB_ID = os.getenv("BEDROCK_KB_ID", "")


@tool
def query_knowledge_base(question: str) -> list:
    """Answer a question from the Bedrock Knowledge Base (read-only).

    Uses the agent's workload identity: Vault vends short-lived Bedrock STS
    creds (aws/sts/bedrock-reader) which back the bedrock-agent-runtime client.
    No user identity is involved — UC1 is non-personalized.

    Args:
        question: The natural-language question to retrieve context for.

    Returns:
        List of retrieved passages (text + score + location).
    """
    global _vault_client
    if _vault_client is None:
        raise RuntimeError("UC1 vault client not initialized")
    if not KB_ID:
        raise RuntimeError("BEDROCK_KB_ID must be set")

    session = _vault_client.get_bedrock_credentials()
    client = session.client("bedrock-agent-runtime")

    logger.info("uc1_kb_retrieve", extra={"kb_id": KB_ID})
    resp = client.retrieve(
        knowledgeBaseId=KB_ID,
        retrievalQuery={"text": question},
    )
    results = []
    for r in resp.get("retrievalResults", []):
        results.append({
            "text": r.get("content", {}).get("text", ""),
            "score": r.get("score"),
            "location": r.get("location"),
        })
    return results


def build_uc1_agent(vault_addr: str, workload_jwt: str) -> Agent:
    """Construct the UC1 Strands agent bound to a Vault client.

    Args:
        vault_addr: Vault address (the OAuth resource server endpoint).
        workload_jwt: The AgentCore workload-identity JWT to present as the
            Vault token (X-Vault-Token).

    Returns:
        A configured Strands Agent exposing the query_knowledge_base tool.
    """
    global _vault_client
    _vault_client = UC1VaultClient(vault_addr=vault_addr)
    _vault_client.set_workload_jwt(workload_jwt)

    model = BedrockModel(model_id=BEDROCK_MODEL_ID)
    return Agent(
        model=model,
        tools=[query_knowledge_base],
        system_prompt=(
            "You are a read-only assistant. Answer strictly from the knowledge "
            "base via the query_knowledge_base tool. You have no user context and "
            "cannot perform writes."
        ),
    )
