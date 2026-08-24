---
title: 'Use Case 2 — Per-user authorization via OBO + Vault'
weight: 60
---

## What you'll prove

The same agent from UC1 now acts **on behalf of an authenticated user**. User
identity propagates from the caller's JWT through AgentCore's On-Behalf-Of (OBO)
token exchange, into Vault, and all the way down to the vended STS credentials.
Vault makes per-user authorization decisions: Alice gets KB access, Bob does not.

## The flow

```text
User (alice@example.com)
  → Bearer JWT to AgentCore Runtime (validates, issues workload access token)
    → Agent calls GetResourceOauth2Token (OBO exchange with token server)
      → Agent gets user-scoped OBO token (sub: alice@example.com)
        → Agent presents OBO token to Vault (auth/jwt/login)
          → Vault matches alice-user role → grants alice-kb policy
            → Vault vends 15m STS creds (session name: vault-jwt-alice@example.com)
              → Agent queries KB with those user-scoped credentials
```

Bob hits the wall at the Vault step. His policy denies `aws/sts/bedrock-reader` and
he gets a 403.

## What changed from UC1

| UC1 | UC2 |
|-----|-----|
| Agent acts as itself | Agent acts on behalf of a user |
| SigV4 inbound auth | JWT bearer inbound auth |
| Execution role or Gateway IAM for KB | Vault-vended STS creds for KB |
| One policy for all callers | Per-user Vault policies |
| No user identity in audit trail | User identity stamped into STS session name |

## Steps

The following pages walk through the build:

1. Deploy the mock OAuth token server
2. Register the OBO credential provider with AgentCore Identity
3. Configure JWT inbound auth on the runtime
4. Wire the OBO exchange and Vault login into the agent code
5. Test: Alice gets access, Bob gets denied
