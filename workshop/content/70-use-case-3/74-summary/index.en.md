---
title: 'UC3 summary'
weight: 74
---

## Security properties of the audit trail

| Property | How it's achieved |
|----------|------------------|
| **Tamper-evident** | Vault hash-chains audit entries. Removing or altering a line breaks the chain. |
| **Non-repudiable** | User identity is cryptographically bound. The JWT signature was verified at login time. The `display_name` in the audit log comes from a validated `sub` claim, not a self-asserted header. |
| **Complete** | Every operation is logged: successes AND failures. Bob's denied request appears with full attribution. |
| **Single-stream** | No reconstruction across trust planes. The JWT carries resolved identity, so one log answers all four questions (who, what, authorization, when). |

## Comparison: before and after

| | EKS workshop (before) | AgentCore workshop (now) |
|-|----------------------|--------------------------|
| Identity source | IVIA decision log | JWT `sub` claim (verified at Vault login) |
| Secret vend record | Vault audit log | Vault audit log (same) |
| Data access record | pgaudit on RDS | CloudTrail (STS session name carries user) |
| Correlation method | Athena JOIN across 3 log sources | Intrinsic: identity baked into JWT and STS session name |
| Time to answer "who did this?" | Minutes (query + join) | Seconds (grep the audit log) |

## What you've proven across all three use cases

| UC | Proven capability |
|----|------------------|
| UC1 | Agent has a workload identity. Vault trusts it. Scoped credentials are vended just-in-time. |
| UC2 | User identity propagates end-to-end via OBO. Vault makes per-user decisions. Alice gets access, Bob does not. |
| UC3 | The audit trail carries full attribution in a single stream. Success and failure are both recorded with the user who triggered them. |

## The design principle

The model (LLM) never holds a credential it could leak. Secrets are injected at
the tool layer, used in a single API call, and discarded. The audit log captures
what happened without the secret value appearing in the agent's context window.

If a prompt injection convinces the agent to call a tool it shouldn't, Vault still
enforces the policy. If the policy allows it, the audit log records it with the
user's identity. The agent is a conduit, not a principal.

## Next steps

- **Production hardening**: Replace the mock OAuth server with a real IdP (Cognito, Okta, Entra). Replace dev-mode Vault with a hardened deployment (auto-unseal, HA Raft, TLS).
- **Dynamic policy mapping**: Use Vault identity entities and groups to map users to policies at scale, rather than one JWT role per user.
- **Log shipping**: Send the Vault audit log to CloudWatch Logs or S3 for retention, alerting, and compliance queries.
- **Guardrails**: Layer AgentCore Gateway's Bedrock Guardrails on top of the runtime to block prompt injections before they reach the tool layer.
