"""Stage 2 credential broker — a stand-in for Vault JWT auth + dynamic secrets.

Flow (mirrors what real Vault does in Stage 3):
  1. Receive a JWT (Authorization: Bearer <jwt> or {"jwt": "..."} body).
  2. Validate it against the trusted JWKS endpoint (signature, iss, aud, exp).
     -> stands in for Vault's JWT auth method + JWKS validation.
  3. Check the JWT `sub` against an allowlist.
     -> stands in for the Vault Agent Registry ("unregistered agents blocked").
  4. sts:AssumeRole into a scoped role and return short-lived credentials.
     -> stands in for Vault's dynamic secrets engine (creds die with the lease).
  5. Log every decision to CloudWatch.  -> stands in for the Vault audit log.

Env vars (set at deploy):
  JWKS_URL          - trusted JWKS document URL (public key half of the workshop keypair)
  EXPECTED_ISS      - expected issuer claim
  EXPECTED_AUD      - expected audience claim (this broker)
  SCOPED_ROLE_ARN   - the role to vend (scoped to bedrock:Retrieve on the KB)
  ALLOWED_SUBS      - comma-separated allowlist of JWT subjects (Agent Registry stand-in)
  CRED_TTL_SECONDS  - vended credential lifetime (default 900)
"""

import json
import logging
import os
import time
import urllib.request

import boto3
import jwt  # PyJWT
from jwt import PyJWKClient

logger = logging.getLogger()
logger.setLevel(logging.INFO)

JWKS_URL = os.environ["JWKS_URL"]
EXPECTED_ISS = os.environ["EXPECTED_ISS"]
EXPECTED_AUD = os.environ.get("EXPECTED_AUD", "vault-standin")
SCOPED_ROLE_ARN = os.environ["SCOPED_ROLE_ARN"]
ALLOWED_SUBS = {s.strip() for s in os.environ.get("ALLOWED_SUBS", "").split(",") if s.strip()}
CRED_TTL_SECONDS = int(os.environ.get("CRED_TTL_SECONDS", "900"))

# PyJWKClient caches keys; reused across warm invocations.
_jwk_client = PyJWKClient(JWKS_URL)
_sts = boto3.client("sts")


def _audit(decision: str, **fields) -> None:
    """Single structured audit line — the Vault-audit-log stand-in."""
    logger.info(json.dumps({"event": "broker_decision", "decision": decision, **fields}))


def _extract_jwt(event: dict) -> str:
    # Direct lambda.invoke: the event IS the payload -> {"jwt": "..."} top-level.
    if isinstance(event, dict) and event.get("jwt"):
        return event["jwt"]
    # Function URL / API GW: Authorization: Bearer header, or a JSON body {"jwt": "..."}.
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    auth = headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    body = event.get("body") or "{}"
    try:
        return (json.loads(body) or {}).get("jwt", "")
    except json.JSONDecodeError:
        return ""


def _response(status: int, payload: dict) -> dict:
    return {"statusCode": status, "headers": {"Content-Type": "application/json"},
            "body": json.dumps(payload)}


def handler(event, context):
    token = _extract_jwt(event)
    if not token:
        _audit("deny", reason="no_token")
        return _response(401, {"error": "missing JWT (Authorization: Bearer <jwt> or body.jwt)"})

    # 2. Validate the JWT against the trusted JWKS (Vault JWT-auth stand-in).
    try:
        signing_key = _jwk_client.get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token, signing_key, algorithms=["RS256"],
            audience=EXPECTED_AUD, issuer=EXPECTED_ISS,
            options={"require": ["exp", "iss", "aud", "sub"]},
        )
    except Exception as e:  # noqa: BLE001 — surface any validation failure as 401
        _audit("deny", reason="jwt_invalid", detail=str(e))
        return _response(401, {"error": f"JWT validation failed: {e}"})

    sub = claims.get("sub", "")
    scope = claims.get("scope", "")

    # 3. Allowlist check (Agent Registry stand-in: unregistered agents blocked).
    if ALLOWED_SUBS and sub not in ALLOWED_SUBS:
        _audit("deny", reason="sub_not_allowlisted", sub=sub)
        return _response(403, {"error": f"subject '{sub}' is not registered/approved"})

    # 4. Vend scoped, short-lived creds (dynamic secrets stand-in).
    try:
        assumed = _sts.assume_role(
            RoleArn=SCOPED_ROLE_ARN,
            RoleSessionName=f"stage2-{sub}"[:64],
            DurationSeconds=CRED_TTL_SECONDS,
        )
    except Exception as e:  # noqa: BLE001
        _audit("error", reason="assume_role_failed", sub=sub, detail=str(e))
        return _response(500, {"error": f"credential vend failed: {e}"})

    creds = assumed["Credentials"]
    _audit("allow", sub=sub, scope=scope, role=SCOPED_ROLE_ARN,
           ttl=CRED_TTL_SECONDS, expiration=creds["Expiration"].isoformat())

    # 5. Return the JIT credentials (same shape the agent would get from Vault's aws engine).
    return _response(200, {
        "access_key_id": creds["AccessKeyId"],
        "secret_access_key": creds["SecretAccessKey"],
        "session_token": creds["SessionToken"],
        "expiration": creds["Expiration"].isoformat(),
        "sub": sub,
        "scope": scope,
    })
