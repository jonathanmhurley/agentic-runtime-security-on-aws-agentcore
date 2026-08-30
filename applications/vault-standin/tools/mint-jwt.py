#!/usr/bin/env python3
"""Mint (sign) a workshop JWT with the local private key.

The JWT represents the AGENT in Stage 2 (sub=uc1-agent), matching UC1's
"agent acts as itself". sub/aud/scopes/issuer are all parameters, so UC2 can
mint a USER-context token later with no code change.

Usage:
  python3 mint-jwt.py --sub uc1-agent --aud vault-standin \
      --iss https://raw.githubusercontent.com/<you>/<repo>/main/jwks/ \
      --scopes kb:read --kid stage2-key-1 --ttl 900 > token.jwt

Requires: pyjwt, cryptography  (pip install pyjwt cryptography)
"""
import argparse
import time
import uuid

import jwt  # PyJWT


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--sub", default="uc1-agent", help="Subject (agent or user id)")
    p.add_argument("--aud", default="vault-standin", help="Audience (the broker)")
    p.add_argument("--iss", required=True, help="Issuer — the JWKS base URL the broker trusts")
    p.add_argument("--scopes", default="kb:read", help="Space-separated scopes")
    p.add_argument("--kid", default="stage2-key-1", help="Key id (must match jwks.json)")
    p.add_argument("--ttl", type=int, default=900, help="Token lifetime in seconds")
    p.add_argument("--client-id", default="workshop-client", help="Client ID (must match Gateway allowedClients)")
    p.add_argument("--key", default="private.pem", help="Path to the signing private key")
    args = p.parse_args()

    now = int(time.time())
    claims = {
        "iss": args.iss,
        "sub": args.sub,
        "aud": args.aud,
        "iat": now,
        "exp": now + args.ttl,
        "scope": args.scopes,
        "jti": str(uuid.uuid4()),
    }
    if args.client_id:
        claims["client_id"] = args.client_id
    key = open(args.key, "rb").read() if not args.key.startswith("-") else args.key
    token = jwt.encode(claims, key, algorithm="RS256", headers={"kid": args.kid})
    print(token)


if __name__ == "__main__":
    main()
