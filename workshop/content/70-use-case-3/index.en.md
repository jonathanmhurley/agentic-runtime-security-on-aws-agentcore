---
title: 'Use Case 3 — Single-plane audit'
weight: 70
---

## What you'll prove

Every operation the agent performs on behalf of a user is recorded in a single,
hash-chained Vault audit log. One log stream answers four questions without a
multi-plane JOIN:

1. **Who** — which authenticated user (`jwt-alice@example.com`)
2. **What** — which secret path was accessed (`aws/sts/bedrock-reader`)
3. **Authorization** — which policy permitted or denied it (`alice-kb`)
4. **When** — ISO timestamp on every entry

Denied requests are logged with the same attribution. If Bob tries and fails, the
audit trail shows exactly who was denied and why.

## Why this matters

The previous version of this workshop (EKS + IVIA) required a three-plane Athena
JOIN to correlate identity across trust boundaries:

| Plane | Source | Correlation key |
|-------|--------|----------------|
| Identity decision | IVIA decision log | Transaction ID |
| Secret vend | Vault audit log | Lease ID |
| Data access | pgaudit (RDS) | Session user |

Reconstructing "Alice caused this DB write" meant joining three logs after the fact.

In the AgentCore edition, the JWT carries **resolved user identity end-to-end**.
Vault stamps that identity into the STS session name, so CloudTrail itself shows
`vault-jwt-alice@example.com-bedrock-reader-<timestamp>`. The correlation key is
intrinsic to the token, not reconstructed.

## Steps

1. Enable the Vault file audit device
2. Generate audit entries by running the UC2 flow
3. Inspect the audit log and trace the full attribution chain
