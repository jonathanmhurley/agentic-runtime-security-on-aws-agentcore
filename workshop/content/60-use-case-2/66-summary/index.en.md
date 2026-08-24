---
title: 'UC2 Summary'
weight: 66
---

## What you proved

An agent on AgentCore Runtime can enforce **per-user authorization** for data-plane
access without embedding any access-control logic in agent code. The authorization
decision lives entirely in Vault policy, evaluated at request time against the
authenticated user's identity.

## Security properties established

| Property | How it's enforced |
|----------|-------------------|
| **No standing credentials** | Agent holds zero AWS credentials for KB access. Every query requires a fresh Vault exchange. |
| **Per-user scoping** | Vault `bound_subject` ties each role to exactly one user identity. Different users get different policies. |
| **Short-lived credentials** | Vault vends STS tokens with 15-minute TTL. Leaked creds expire quickly. |
| **Auditable identity chain** | The STS session name contains the user email (`vault-jwt-alice@example.com`), visible in CloudTrail. |
| **Separation of concerns** | Agent code handles orchestration. Vault handles authorization. Neither can be bypassed independently. |
| **Fail-closed** | Missing WAT, failed OBO exchange, or Vault denial all produce errors before any KB call happens. |

## Control objectives advanced

- **OBJ-1** (verifiable agent identity): JWT inbound auth validates the agent caller;
  OBO exchange stamps user identity into downstream tokens.
- **OBJ-2** (no standing privileges): Agent can't reach the KB without going through
  Vault first. No IAM policy on the execution role grants `bedrock:Retrieve`.
- **OBJ-3** (per-user authorization): Vault policies (`alice-kb` vs `bob-kb`) enforce
  who can read what. This is the first UC where access varies by caller.
- **OBJ-5** (audit trail): User identity is embedded in the STS session name and
  Vault audit log. You can trace any KB query back to the human who initiated it.

## Architecture diagram

```text
┌─────────────┐     JWT      ┌──────────────────┐     WAT      ┌────────────────┐
│  End User   │─────────────>│  AgentCore       │─────────────>│  Agent Code    │
│ (alice/bob) │              │  Runtime         │              │  (app.py)      │
└─────────────┘              └──────────────────┘              └───────┬────────┘
                                                                       │
                                                          OBO Exchange │ (1)
                                                                       ▼
                                                               ┌───────────────┐
                                                               │ Token Server  │
                                                               │ (mock Lambda) │
                                                               └───────┬───────┘
                                                                       │
                                                          OBO Token     │ (2)
                                                                       ▼
                                                               ┌───────────────┐
                                                               │    Vault      │
                                                               │  (JWT auth)   │
                                                               └───────┬───────┘
                                                                       │
                                                          STS Creds    │ (3)
                                                                       ▼
                                                               ┌───────────────┐
                                                               │  Bedrock KB   │
                                                               │  (Meridian)   │
                                                               └───────────────┘
```

## What's next

UC3 adds **write operations with dynamic database credentials**. Same Vault pattern,
but instead of read-only STS for a KB, Vault vends short-lived database credentials
scoped to a specific schema. The agent can mutate data on behalf of the user, with
full audit lineage and automatic credential rotation.
