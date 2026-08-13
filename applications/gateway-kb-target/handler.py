"""Gateway KB target — a thin Lambda that wraps bedrock:Retrieve.

This is a Gateway target, NOT a standalone API. Gateway calls it with
GATEWAY_IAM_ROLE outbound auth (the Gateway's own role holds bedrock:Retrieve
on the Meridian KB). The Lambda just passes the query through and returns passages.

Input (from Gateway MCP tool call):
    {"query": "RapidLane SLA"}

Output (returned to Gateway -> caller):
    {"passages": [{"text": "...", "score": ..., "location": ...}, ...]}
"""
import json
import os

import boto3

KB_ID = os.environ.get("BEDROCK_KB_ID", "QLKOTZM2GC")
REGION = os.environ.get("AWS_REGION", "us-east-1")

client = boto3.client("bedrock-agent-runtime", region_name=REGION)


def handler(event, context):
    # Gateway sends the tool arguments as the event body
    if isinstance(event, str):
        event = json.loads(event)
    query = event.get("query", "")
    if not query:
        return {"statusCode": 400, "body": json.dumps({"error": "missing query parameter"})}

    resp = client.retrieve(
        knowledgeBaseId=KB_ID,
        retrievalQuery={"text": query},
    )
    passages = []
    for r in resp.get("retrievalResults", []):
        passages.append({
            "text": r.get("content", {}).get("text", ""),
            "score": r.get("score"),
            "location": r.get("location"),
        })

    return {"statusCode": 200, "body": json.dumps({"passages": passages})}
