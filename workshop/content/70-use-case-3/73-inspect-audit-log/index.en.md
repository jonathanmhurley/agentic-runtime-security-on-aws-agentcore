---
title: 'Inspect the audit log'
weight: 73
---

## Read the audit entries

SSH to the Vault instance and inspect the most recent entries:

```bash
ssh -i ~/.ssh/vault-workshop.pem ec2-user@<VAULT_IP> \
  "sudo tail -8 /var/log/vault-audit.log" | python3 -c "
import sys, json
for line in sys.stdin:
    entry = json.loads(line.strip())
    req = entry.get('request', {})
    auth = entry.get('auth', {})
    resp = entry.get('response', {})
    error = entry.get('error', '')
    print(f\"Type: {entry['type']:8s}  Path: {req.get('path',''):30s}  \
User: {auth.get('display_name','N/A'):30s}  Policies: {auth.get('policies',[])}  \
Error: {error or 'none'}\")"
```

## Expected output

You should see entries for both Alice and Bob:

```text
Type: request   Path: auth/jwt/login                  User: token                           Policies: ['root']           Error: none
Type: response  Path: auth/jwt/login                  User: jwt-alice@example.com           Policies: ['alice-kb', 'default']  Error: none
Type: request   Path: aws/sts/bedrock-reader           User: jwt-alice@example.com           Policies: ['alice-kb', 'default']  Error: none
Type: response  Path: aws/sts/bedrock-reader           User: jwt-alice@example.com           Policies: ['alice-kb', 'default']  Error: none
Type: request   Path: auth/jwt/login                  User: token                           Policies: ['root']           Error: none
Type: response  Path: auth/jwt/login                  User: jwt-bob@example.com             Policies: ['bob-kb', 'default']    Error: none
Type: request   Path: aws/sts/bedrock-reader           User: jwt-bob@example.com             Policies: ['bob-kb', 'default']    Error: none
Type: response  Path: aws/sts/bedrock-reader           User: jwt-bob@example.com             Policies: ['bob-kb', 'default']    Error: permission denied
```

## Reading the attribution chain

Each pair of entries (request + response) shares a `request.id`. For Alice's STS
vend:

| Field | Value | Meaning |
|-------|-------|---------|
| `auth.display_name` | `jwt-alice@example.com` | The user the agent acted on behalf of |
| `auth.policies` | `['alice-kb', 'default']` | Authorization granted by Vault |
| `request.path` | `aws/sts/bedrock-reader` | The secret engine path accessed |
| `response` data | STS access key + ARN | The credential actually vended |
| `time` | ISO timestamp | When this happened |
| `error` | empty | Operation succeeded |

For Bob's denied attempt, the same fields are populated but `error` shows
`permission denied`. The denial is attributed: you know exactly who tried and failed.

## CloudTrail correlation

The STS credential Vault vended for Alice produces this assumed-role ARN:

```text
vault-jwt-alice@example.com-bedrock-reader-<unix-timestamp>-<random>
```

Any AWS API call made with those credentials (the KB retrieve, for example) shows
that session name in CloudTrail. Without touching the Vault log at all, a CloudTrail
query for `userIdentity.arn LIKE '%alice@example.com%'` returns every action the
agent took on Alice's behalf.

## The full picture

```text
Vault audit log entry:
  auth/jwt/login        -> jwt-alice@example.com authenticated, policies: alice-kb
  aws/sts/bedrock-reader -> STS creds vended, session: vault-jwt-alice@example.com-...

CloudTrail entry:
  bedrock:Retrieve      -> assumed-role/Stage2VendedKBReadRole/vault-jwt-alice@example.com-...
```

One user, one agent, one authorization decision, one credential, one data access.
All linked by the identity baked into the JWT at the start of the chain.
