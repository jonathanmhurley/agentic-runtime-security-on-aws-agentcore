# vault-standin — Stage 2 credential broker

A faithful, AWS-native **stand-in for HashiCorp Vault's JWT auth + dynamic secrets**,
so we can prove the full "present JWT -> validate -> receive scoped JIT creds" flow
before real Vault exists (Stage 3). The agent's tool interface is identical to what
it will use against Vault, so the Stage 3 swap changes an endpoint, not agent logic.

## What it stands in for

| Real Vault (Stage 3) | This stand-in (Stage 2) |
|---|---|
| JWT auth method validates the token via a JWKS endpoint | Broker Lambda fetches `jwks.json` and validates signature/iss/aud/exp |
| Agent Registry: is this agent registered + approved? | Broker allowlist check on the JWT `sub` |
| Dynamic secrets engine vends short-lived creds | Broker `sts:AssumeRole` into a scoped role, returns temp creds |
| Vault audit log | CloudWatch Logs on every broker decision |

## JWT approach (Option B — local keypair + hosted JWKS)

No Cognito/IdP. We generate an RSA keypair once, publish the **public** key as a
`jwks.json` at a GitHub raw URL, and sign workshop JWTs locally with the private key.
The broker (and later Vault) trust that JWKS URL. This exercises the real
JWKS-validation path while keeping everything self-contained and inspectable.

```
tools/keygen.sh          # one-time: RSA keypair + jwks.json (kid-stamped)
tools/mint-jwt.py        # sign a JWT (sub/aud/scopes are parameters)
broker/handler.py        # Lambda: validate JWT via JWKS -> allowlist -> vend STS creds
broker/deploy.sh         # package + deploy broker Lambda + scoped role + function URL
```

## Trust chain (what the workshop teaches)
1. `keygen.sh` makes `private.pem` (signs) + `jwks.json` (verifies). Publish `jwks.json`
   to a GitHub raw URL; keep `private.pem` local (gitignored — never committed).
2. `mint-jwt.py` signs a JWT for `sub=uc1-agent`, `aud=vault-standin`, with scopes.
3. Agent calls the broker with the JWT. Broker fetches JWKS, verifies signature +
   iss + aud + exp, checks `sub` against the allowlist, then `sts:AssumeRole` into the
   scoped role and returns short-lived creds.
4. Agent uses those creds (Stage 3: identical, but Vault is the broker).

> Private keys and minted tokens are gitignored. Only `jwks.json` (public) is shareable.
