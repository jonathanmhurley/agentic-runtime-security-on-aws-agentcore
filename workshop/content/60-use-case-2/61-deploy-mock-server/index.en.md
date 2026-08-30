---
title: 'Deploy the mock OAuth token server'
weight: 61
---

## Why a mock server?

AgentCore's OBO exchange needs a token endpoint that accepts a client-credentials +
assertion grant and returns a user-scoped token. In production this would be your
corporate IdP (Okta, Entra ID, Auth0). For the workshop we deploy a minimal Lambda
that does the same thing with zero external dependencies.

The mock server:

- Exposes `/.well-known/openid-configuration` (OIDC discovery)
- Exposes `/token` (accepts `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`)
- Validates basic auth credentials (client ID + secret)
- Copies the `sub` claim from the inbound assertion into the new token
- Signs the output token with a workshop RSA key
- Serves JWKS at `/jwks.json` (proxied from the GitHub-hosted workshop JWKS)

## Deploy

```bash
cd ~/agentic-runtime-security-on-aws-agentcore/applications/oauth-mock-server
bash deploy.sh
```

The script creates a Lambda function (`oauth-mock-server`) with a Function URL
(AuthType: NONE) and prints the URL on completion. Save it:

```bash
export FUNCTION_URL="<FUNCTION_URL>"
```

{{% notice note %}}
If your account has org SCPs that block unauthenticated Lambda Function URL
invocations (common on internal Amazon accounts), use `deploy-dev.sh` instead.
It places an API Gateway HTTP API in front of the Lambda and prints the equivalent
base URL.
{{% /notice %}}

## Verify

```bash
curl -s "$FUNCTION_URL/.well-known/openid-configuration" | python3 -m json.tool
```

Expected output includes `token_endpoint`, `jwks_uri`, and `authorization_endpoint`
all pointing at your Function URL.

```bash
curl -s "$FUNCTION_URL/jwks.json" | python3 -m json.tool
```

Confirm you see at least one RSA key with `use: sig`.

## What this gives you

A standards-compliant OIDC token endpoint that AgentCore Identity can call during
the OBO exchange. The signed tokens it issues will be presented to Vault in the next
steps.
