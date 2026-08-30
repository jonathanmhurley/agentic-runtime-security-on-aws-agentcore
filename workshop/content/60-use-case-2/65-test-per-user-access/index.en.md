---
title: 'Test: Alice gets access, Bob gets denied'
weight: 65
---

## Mint user JWTs

Generate tokens for two users via the mock OAuth server. Both are valid, signed JWTs
that the runtime authorizer will accept. The difference is the `sub` claim.

```bash
cd applications/stage0hello

# Alice
aws lambda invoke --function-name oauth-mock-server \
  --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"username":"alice@example.com"}' \
  /tmp/alice-jwt.json >/dev/null

ALICE_JWT=$(python3 -c "import json; r=json.load(open('/tmp/alice-jwt.json')); print(r.get('access_token') or json.loads(r.get('body','{}')).get('access_token',''))")

# Bob
aws lambda invoke --function-name oauth-mock-server \
  --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"username":"bob@example.com"}' \
  /tmp/bob-jwt.json >/dev/null

BOB_JWT=$(python3 -c "import json; r=json.load(open('/tmp/bob-jwt.json')); print(r.get('access_token') or json.loads(r.get('body','{}')).get('access_token',''))")
```

## Test Alice (should succeed)

```bash
agentcore invoke --bearer-token "$ALICE_JWT" "What is RapidLane's SLA?"
```

Expected: The agent returns a detailed answer from the Knowledge Base, including the
6-hour delivery window, 25% credit for misses, and priority score of 7.

## Test Bob (should fail)

```bash
agentcore invoke --bearer-token "$BOB_JWT" "What is RapidLane's SLA?"
```

Expected: The agent returns an error. The agent code has `VAULT_JWT_ROLE` defaulting
to `alice-user`, so when Bob's OBO token (with `sub: bob@example.com`) is presented to
Vault's `alice-user` role, Vault rejects it because `bound_subject` doesn't match:

```text
invalid subject (sub) claim
```

Bob authenticated successfully at the Runtime level (his JWT was valid, the OBO
exchange worked). But Vault rejected his token at login because the role is bound
to a different subject. This is the allowlist in action.

{{% notice tip %}}
In a production system, the agent would resolve the Vault role dynamically from
the user's `sub` claim. For the workshop, the hardcoded role demonstrates the
bound_subject enforcement clearly.
{{% /notice %}}

## What to observe

| Step | Alice | Bob |
|------|-------|-----|
| JWT accepted by Runtime | Yes | Yes |
| OBO exchange returns token | Yes (sub: alice@example.com) | Yes (sub: bob@example.com) |
| Vault JWT login | Succeeds (alice-user role, bound_subject matches) | **Fails** (alice-user role, bound_subject mismatch) |
| Vault STS creds vended | Yes (alice-kb policy allows) | N/A |
| KB query returns answer | Yes | N/A |

## Check the audit trail

On the Vault server, examine the audit log:

```bash
ssh -i ~/.ssh/vault-workshop.pem ec2-user@<VAULT_IP> \
  "sudo tail -4 /var/log/vault-audit.log" | python3 -c "
import sys, json
for line in sys.stdin:
    entry = json.loads(line.strip())
    req = entry.get('request', {})
    auth = entry.get('auth', {})
    print(f\"Type: {entry.get('type')}  Path: {req.get('path')}  User: {auth.get('display_name', 'N/A')}  Policies: {auth.get('policies', [])}\")"
```

You'll see Alice's login and STS vend both show `display_name: jwt-alice@example.com`
with policies `[alice-kb, default]`. Bob's denied attempt also appears in the log with
full attribution.

## The security property

The agent code is identical for both users. It doesn't make access decisions. Vault
does. The agent cannot bypass this because it never holds standing credentials for the
KB. Every request requires a fresh Vault exchange, and Vault checks the user's identity
every time.
