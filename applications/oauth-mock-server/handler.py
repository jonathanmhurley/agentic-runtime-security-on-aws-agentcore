"""Mock OAuth token server — issues user-identity JWTs for UC2 OBO demos.

A minimal OIDC-compliant token issuer that:
- POST /token — accepts a username, returns a signed JWT (sub=<username>, act.sub=uc1-agent)
- GET /.well-known/openid-configuration — returns OIDC discovery doc
- GET /jwks.json — proxies to the GitHub-hosted JWKS (or returns it inline)

The Lambda uses the same RSA private key as the workshop's mint-jwt.py. In a real
deployment, the key would be in Secrets Manager; for the workshop it's bundled.

This is NOT a production IdP — it's a workshop mock that lets us test AgentCore's
OBO exchange with a real token endpoint.
"""

import json
import os
import time
import uuid

import jwt  # PyJWT

# The private key is bundled in the Lambda zip (workshop-only, not a real secret)
PRIVATE_KEY_PATH = os.environ.get("PRIVATE_KEY_PATH", "private.pem")
ISSUER = os.environ.get("ISSUER", "https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin")
JWKS_URL = os.environ.get("JWKS_URL", f"{ISSUER}/jwks.json")
AUDIENCE = os.environ.get("AUDIENCE", "vault-standin")
KID = os.environ.get("KID", "stage2-key-1")
TOKEN_TTL = int(os.environ.get("TOKEN_TTL", "900"))
AGENT_SUB = os.environ.get("AGENT_SUB", "uc1-agent")

# Load private key at cold start
_private_key = None


def _get_key():
    global _private_key
    if _private_key is None:
        _private_key = open(PRIVATE_KEY_PATH, "rb").read()
    return _private_key


def _discovery():
    return {
        "issuer": ISSUER,
        "jwks_uri": JWKS_URL,
        "token_endpoint": "THIS_LAMBDA_URL/token",
        "response_types_supported": ["token"],
        "subject_types_supported": ["public"],
        "id_token_signing_alg_values_supported": ["RS256"],
        "grant_types_supported": ["client_credentials"],
        "token_endpoint_auth_methods_supported": ["private_key_jwt"],
    }


def _issue_token(username: str) -> str:
    """Issue a user-delegated JWT (user sub + agent act.sub)."""
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "sub": username,
        "aud": AUDIENCE,
        "iat": now,
        "exp": now + TOKEN_TTL,
        "jti": str(uuid.uuid4()),
        "scope": "kb:read",
        "act": {"sub": AGENT_SUB},  # RFC 8693 actor claim (the agent acting on behalf)
    }
    return jwt.encode(claims, _get_key(), algorithm="RS256", headers={"kid": KID})


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
        "body": json.dumps(body),
    }


def handler(event, context):
    # Direct lambda.invoke: event IS the payload
    # Function URL / API GW: event has requestContext, path, httpMethod
    path = event.get("rawPath", event.get("path", ""))
    method = event.get("requestContext", {}).get("http", {}).get("method", event.get("httpMethod", "POST"))

    # Also handle direct invoke (no path) — treat as token request
    if not path and "username" in (event if isinstance(event, dict) else {}):
        username = event.get("username", "anonymous")
        token = _issue_token(username)
        return _response(200, {"access_token": token, "token_type": "Bearer", "expires_in": TOKEN_TTL, "sub": username})

    if path.endswith("/.well-known/openid-configuration"):
        return _response(200, _discovery())

    if path.endswith("/jwks.json"):
        # Proxy to the GitHub JWKS (or return it inline if bundled)
        import urllib.request
        try:
            with urllib.request.urlopen(JWKS_URL, timeout=5) as r:
                return _response(200, json.loads(r.read()))
        except Exception as e:
            return _response(500, {"error": f"Failed to fetch JWKS: {e}"})

    if path.endswith("/token") or method == "POST":
        # Parse username from body or query
        body = event.get("body", "{}")
        if isinstance(body, str):
            try:
                body = json.loads(body)
            except json.JSONDecodeError:
                body = {}
        username = body.get("username", event.get("username", "anonymous"))
        token = _issue_token(username)
        return _response(200, {"access_token": token, "token_type": "Bearer", "expires_in": TOKEN_TTL, "sub": username})

    return _response(404, {"error": f"Unknown path: {path}"})
