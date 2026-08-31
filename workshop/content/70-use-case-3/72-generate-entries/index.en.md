---
title: 'Generate audit entries'
weight: 72
---

## Run the UC2 flow for Alice

This generates audit entries for a successful authentication + credential vend:

```bash
# Mint Alice's JWT:
aws lambda invoke --function-name oauth-mock-server \
  --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"username":"alice@example.com"}' \
  /tmp/alice-jwt.json >/dev/null

ALICE_JWT=$(python3 -c "import json; r=json.load(open('/tmp/alice-jwt.json')); \
  print(r.get('access_token') or json.loads(r.get('body','{}')).get('access_token',''))")

# Login to Vault:
ALICE_TOKEN=$(vault write -format=json auth/jwt/login role=alice-user jwt="$ALICE_JWT" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

# Vend STS credentials:
VAULT_TOKEN=$ALICE_TOKEN vault write aws/sts/bedrock-reader ttl=15m
```

You should see STS credentials returned, including an ARN like:

```text
arn:aws:sts::<ACCOUNT_ID>:assumed-role/Stage2VendedKBReadRole/vault-jwt-alice@example.com-bedrock-reader-<timestamp>
```

Note the session name: Vault stamps the user identity directly into it.

## Run the UC2 flow for Bob (denied)

Bob authenticates successfully but is denied at the STS vend step:

```bash
aws lambda invoke --function-name oauth-mock-server \
  --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"username":"bob@example.com"}' \
  /tmp/bob-jwt.json >/dev/null

BOB_JWT=$(python3 -c "import json; r=json.load(open('/tmp/bob-jwt.json')); \
  print(r.get('access_token') or json.loads(r.get('body','{}')).get('access_token',''))")

# Login succeeds (Bob is a valid user):
BOB_TOKEN=$(vault write -format=json auth/jwt/login role=bob-user jwt="$BOB_JWT" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

# STS vend fails (bob-kb denies this path):
VAULT_TOKEN=$BOB_TOKEN vault write aws/sts/bedrock-reader ttl=15m
```

Expected error:

```text
Error writing data to aws/sts/bedrock-reader:
Code: 403. Errors:
  * 1 error occurred:
    * permission denied
```

Both Alice's success and Bob's denial generated audit entries. Proceed to inspection.
