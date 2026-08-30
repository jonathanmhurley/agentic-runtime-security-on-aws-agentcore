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

{{% notice warning %}}
A runtime can support either IAM SigV4 or JWT inbound auth, but not both. After
this step, `agentcore invoke "hello"` (SigV4) will return a 403. All invocations
must include `--bearer-token`.
{{% /notice %}}

## Add the authorizer

Edit `applications/stage0hello/agentcore/agentcore.json`. Inside the runtime entry
in the `runtimes` array, add `authorizerType` and `authorizerConfiguration`:

```json
{
  "$schema": "https://schema.agentcore.aws.dev/v1/agentcore.json",
  "name": "stage0hello",
  "runtimes": [
    {
      "name": "stage0hello",
      "build": "CodeZip",
      "entrypoint": "main.py",
      "codeLocation": "app/stage0hello/",
      "runtimeVersion": "PYTHON_3_14",
      "networkMode": "PUBLIC",
      "protocol": "HTTP",
      "authorizerType": "CUSTOM_JWT",
      "authorizerConfiguration": {
        "customJwtAuthorizer": {
          "discoveryUrl": "<MOCK_SERVER_URL>/.well-known/openid-configuration",
          "allowedAudience": [
            "vault-standin"
          ]
        }
      }
    }
  ]
}
```

{{% notice tip %}}
The authorizer **must** be in `agentcore.json`, not applied via the CLI
`update-agent-runtime` command. CDK overwrites the runtime config from
`agentcore.json` on every deploy, so manual changes are lost. Replace
`<MOCK_SERVER_URL>` with your actual API Gateway URL before deploying.
{{% /notice %}}

Deploy the updated config:

```bash
cd applications/stage0hello
agentcore deploy --yes
```

## What happens at request time

When a caller invokes the agent with `--bearer-token`:

1. AgentCore Runtime fetches the JWKS from the discovery URL
2. It validates the token signature, expiry, and audience
3. It issues a **workload access token** (WAT) bound to the validated user
4. It passes the WAT in `context.request_headers['workloadaccesstoken']`

The agent can then use the WAT in downstream calls (next step).

## Test the authorizer

Mint a user JWT via the mock server and invoke:

```bash
aws lambda invoke --function-name oauth-mock-server --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"username":"alice@example.com"}' \
  /tmp/user-jwt.json >/dev/null

USER_JWT=$(python3 -c "import json; r=json.load(open('/tmp/user-jwt.json')); print(r.get('access_token') or json.loads(r.get('body','{}')).get('access_token',''))")

agentcore invoke --bearer-token "$USER_JWT" "hello"
```

If the authorizer is misconfigured, you'll get an `Unauthorized` error before the
agent code runs. A successful response (even a generic greeting) confirms the JWT
was accepted.

## Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Authorization method mismatch` | Config not deployed | Re-run `agentcore deploy` |
| `Unauthorized` immediately | Audience mismatch | Check `allowedAudience` matches the `aud` claim in your JWT |
| `Unauthorized` immediately | JWKS unreachable | Confirm `curl $MOCK_SERVER_URL/.well-known/openid-configuration` returns JSON |
| Agent runs but no WAT | Authorizer not in `agentcore.json` | Verify the `authorizerType` field is present in the runtime entry, redeploy |
