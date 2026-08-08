#!/usr/bin/env python3
"""Convert an RSA public key PEM into a single-key JWKS document (RS256).

Usage: python3 pem_to_jwks.py public.pem <kid>
Prints jwks.json to stdout.
"""
import base64
import json
import sys


def _b64url_uint(n: int) -> str:
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def main() -> None:
    pem_path, kid = sys.argv[1], sys.argv[2]
    # Lazy import so keygen works even if cryptography is only needed here.
    from cryptography.hazmat.primitives.serialization import load_pem_public_key

    pub = load_pem_public_key(open(pem_path, "rb").read())
    numbers = pub.public_numbers()
    jwk = {
        "kty": "RSA",
        "use": "sig",
        "alg": "RS256",
        "kid": kid,
        "n": _b64url_uint(numbers.n),
        "e": _b64url_uint(numbers.e),
    }
    print(json.dumps({"keys": [jwk]}, indent=2))


if __name__ == "__main__":
    main()
