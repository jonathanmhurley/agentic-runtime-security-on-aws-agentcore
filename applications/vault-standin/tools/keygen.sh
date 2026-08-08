#!/usr/bin/env bash
# One-time: generate an RSA keypair and a JWKS document for Stage 2.
#   private.pem  -> signs workshop JWTs (KEEP LOCAL, gitignored)
#   public.pem   -> the public half
#   jwks.json    -> publish to a GitHub raw URL; broker + Vault trust it
# Requires: openssl, python3 (for the JWKS conversion).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."

KID="stage2-key-1"

if [ -f private.pem ]; then
  echo "[keygen] private.pem already exists — refusing to overwrite. Delete it first to regenerate."
  exit 0
fi

echo "[keygen] generating RSA 2048 keypair"
openssl genrsa -out private.pem 2048 2>/dev/null
openssl rsa -in private.pem -pubout -out public.pem 2>/dev/null

echo "[keygen] building jwks.json (kid=$KID)"
python3 "$HERE/pem_to_jwks.py" public.pem "$KID" > jwks.json

echo "[keygen] done:"
echo "  private.pem  (KEEP LOCAL — gitignored)"
echo "  public.pem   (public half)"
echo "  jwks.json    (publish to a GitHub raw URL, e.g. a gist or repo file)"
echo
echo "Next: publish jwks.json and note its raw URL as JWKS_URL for the broker + minter."
