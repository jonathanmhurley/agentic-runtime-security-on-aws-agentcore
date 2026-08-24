---
title: 'Configure JWT inbound auth'
weight: 63
---

## Why JWT inbound auth?

UC1 used SigV4 (IAM) authentication to invoke the agent. That proves the *caller*
has IAM credentials but doesn't carry end-user identity. For UC2 we switch to
**JWT bearer** so the calling user's identity (`sub` claim) rides the request all the
way into the agent.

AgentCore validates the JWT on the way in, rejects bad signatures or expired tokens,
and makes the user's workload access token (WAT) available to the agent code.

## Add the authorizer

Edit `applications/stage0hello/agentcore/.agentcore/agentcore.json` and add the
`authorizerConfiguration` block:

```json
{
  "schemaVersion": "1.0",
  "runtime": {
    "authorizerConfiguration": {
      "customJWTAuthorizer": {
        "discoveryUrl": "<FUNCTION_URL>/.well-known/openid-configuration",
        "allowedAudience": ["vault-standin"],
        "allowedClients": []
      }
    }
  }
}
```

Push the config:

```bash
cd applications/stage0hello/agentcore
agentcore configure
```

## What happens at request time

When a caller invokes the agent with `--bearer-token`:

1. AgentCore Runtime fetches the JWKS from the discovery URL
2. It validates the token signature, expiry, and audience
3. It issues a **workload access token** (WAT) bound to the validated user
4. It passes the WAT in `context.request_headers['workloadaccesstoken']`

The agent can then use the WAT in downstream calls (next step).

## Test the authorizer

Generate a user JWT and invoke:

```bash
USER_JWT=$(python3 tools/mint-jwt.py \
  --sub alice@example.com \
  --aud vault-standin \
  --iss "<FUNCTION_URL>" \
  --kid workshop-key-1 \
  --ttl 3600)

agentcore invoke --bearer-token "$USER_JWT" "hello"
```

If the authorizer is misconfigured, you'll get an `Unauthorized` error before the
agent code runs. A successful response (even a generic greeting) confirms the JWT
was accepted.

## Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Unauthorized` immediately | Audience mismatch | Check `allowedAudience` matches the `aud` claim in your JWT |
| `Unauthorized` immediately | JWKS unreachable | Confirm `curl <FUNCTION_URL>/.well-known/openid-configuration` returns JSON |
| Agent runs but no WAT | Config not pushed | Re-run `agentcore configure` and restart |
