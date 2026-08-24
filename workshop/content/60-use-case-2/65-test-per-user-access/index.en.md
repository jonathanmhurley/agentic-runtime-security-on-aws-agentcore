---
title: 'Test: Alice gets access, Bob gets denied'
weight: 65
---

## Mint user JWTs

Generate tokens for two users. Both are valid, signed JWTs that the authorizer will
accept. The difference is the `sub` claim.

```bash
cd applications/stage0hello/agentcore

# Alice
ALICE_JWT=$(python3 ../../vault-standin/tools/mint-jwt.py \
  --sub alice@example.com \
  --aud vault-standin \
  --iss "<FUNCTION_URL>" \
  --kid workshop-key-1 \
  --ttl 3600)

# Bob
BOB_JWT=$(python3 ../../vault-standin/tools/mint-jwt.py \
  --sub bob@example.com \
  --aud vault-standin \
  --iss "<FUNCTION_URL>" \
  --kid workshop-key-1 \
  --ttl 3600)
```

## Test Alice (should succeed)

Set the Vault role to `alice-user` in your environment, then invoke:

```bash
export VAULT_JWT_ROLE=alice-user

agentcore invoke --bearer-token "$ALICE_JWT" "What is RapidLane's SLA?"
```

Expected: The agent returns a detailed answer from the Knowledge Base, including the
6-hour delivery window, 25% credit for misses, and priority score of 7.

## Test Bob (should fail)

Switch the Vault role to `bob-user`:

```bash
export VAULT_JWT_ROLE=bob-user

agentcore invoke --bearer-token "$BOB_JWT" "What is RapidLane's SLA?"
```

Expected: The agent returns an error. Vault denies Bob's token access to the
`aws/sts/bedrock-reader` path because `bob-kb` policy has an explicit deny:

```text
1 error occurred:
  * permission denied
```

Bob authenticated successfully (his JWT was valid, the OBO exchange worked, Vault
accepted his login). But authorization failed: his policy does not grant access to
the STS secret engine.

## What to observe

| Step | Alice | Bob |
|------|-------|-----|
| JWT accepted by Runtime | Yes | Yes |
| OBO exchange returns token | Yes (sub: alice@example.com) | Yes (sub: bob@example.com) |
| Vault JWT login succeeds | Yes (role: alice-user) | Yes (role: bob-user) |
| Vault STS creds vended | Yes (alice-kb allows) | **No** (bob-kb denies) |
| KB query returns answer | Yes | N/A |

## Check the audit trail

On the Vault server, examine the audit log:

```bash
ssh ec2-user@<VAULT_IP>
sudo cat /var/log/vault/audit.log | python3 -m json.tool | grep -A5 '"path"'
```

You'll see both login attempts succeeded, but Bob's subsequent request to
`aws/sts/bedrock-reader` was denied. The `display_name` field shows
`vault-jwt-bob@example.com`, proving user identity propagated into the audit trail.

## The security property

The agent code is identical for both users. It doesn't make access decisions. Vault
does. The agent cannot bypass this because it never holds standing credentials for the
KB. Every request requires a fresh Vault exchange, and Vault checks the user's policy
every time.
