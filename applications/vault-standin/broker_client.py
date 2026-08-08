"""broker_client.py — agent-side client for the Stage 2 credential broker.

Drop-in shape-compatible with the Stage 3 Vault client: call get_scoped_credentials(jwt)
and receive short-lived AWS creds. In Stage 3 this same method points at Vault's
OAuth resource server instead of the broker Lambda — the agent tool code does not change.

Authorization is the JWT itself: the broker validates it via JWKS + allowlist and, only
then, vends scoped credentials. The Function URL uses AuthType NONE — there is no AWS
SigV4 transport layer — which mirrors Vault (it authorizes on the presented token, not on
AWS IAM) and avoids the AgentCore-Runtime outbound-SigV4 mismatch an IAM-auth URL hit.
"""

import json
import os
import urllib.request


def get_scoped_credentials(jwt_token: str, broker_url: str | None = None) -> dict:
    """Exchange a workshop JWT at the broker for short-lived scoped AWS credentials.

    Args:
        jwt_token: the minted RS256 JWT (sub=uc1-agent, aud=vault-standin, ...).
        broker_url: the broker Function URL (defaults to $BROKER_URL).

    Returns:
        Dict: {access_key_id, secret_access_key, session_token, expiration, sub, scope}.

    Raises:
        RuntimeError on non-200 from the broker (surfaces deny/allowlist/validation errors).
    """
    url = broker_url or os.environ["BROKER_URL"]
    body = json.dumps({"jwt": jwt_token}).encode()
    req = urllib.request.Request(
        url, data=body, method="POST", headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"broker denied ({e.code}): {e.read().decode()}") from e
