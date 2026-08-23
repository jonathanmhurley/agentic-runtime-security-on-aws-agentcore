# oauth-mock-server — UC2 token issuer

A minimal OIDC-compliant mock token server for the UC2 on-behalf-of (OBO) demos.
Issues user-identity JWTs signed with the workshop's RS256 keypair.

## What it does
- Issues JWTs with `sub: <username>` + `act: { sub: uc1-agent }` (RFC 8693 delegation)
- Uses the same private key + JWKS as the rest of the workshop
- Invoked via `lambda.invoke` (same pattern as all other workshop Lambdas)

## Deploy
```bash
bash deploy.sh
```

## Usage
```bash
# Get a user token for "alice"
aws lambda invoke --function-name oauth-mock-server \
  --payload '{"username":"alice@example.com"}' /tmp/token.json --profile agenticvault --region us-east-1
cat /tmp/token.json | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'][:50]+'...')"
```

## Not a real IdP
This is a workshop mock — no real user database, no password check, no MFA.
Anyone who can invoke the Lambda can get a token for any username. That is
intentional for a security-concepts lab.
