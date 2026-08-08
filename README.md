# Agentic Runtime Security on AWS — AgentCore Edition

Step-by-step **hands-on** AWS Workshop Studio workshop that deploys the **Amazon Bedrock AgentCore + HashiCorp Vault** reference architecture for runtime AI agent security — **no EKS, no IVIA, no OpenLDAP**. Agents run on AgentCore Runtime (managed, serverless); AgentCore Identity issues the user-context JWT that Vault validates via JWKS; Vault vends short-lived JIT credentials and provides the single audit trail.

This is a **new repository**, a pivot of the EKS/IVIA reference workshop (`agentic-runtime-security-on-aws`). It mirrors that repo's structure for reviewer familiarity and deviates only where AgentCore forces it. See `docs/DESIGN.md` for the full target-architecture design.

**Duration:** ~2 hours end-to-end.

**Audience:** workshop admins running this for their orgs. Attendee-facing pages live in `workshop/content/`.

---

## What you'll build

Three progressively-layered Strands agents on **AgentCore Runtime**, brokered through **HashiCorp Vault Enterprise**, with a single correlated audit trail:

1. **Use Case 1** — Non-personalized read-only agent (agent workload identity, JIT credentials, reads Bedrock KB)
2. **Use Case 2** — OAuth personalized read agent (user intent via OIDC + PKCE, carried on-behalf-of through AgentCore OBO)
3. **Use Case 3** — Privileged write + single-plane Vault audit (user + agent + authorization + lease in one hash-chained log)

---

## Architecture at a glance

| Plane | Component |
|---|---|
| Agent hosting | Amazon Bedrock AgentCore Runtime (Strands) — no EKS |
| Agent identity / token issuer | AgentCore Identity (workload ARN + user-context JWT + JWKS) |
| User delegation | AgentCore Secure Token Vault + native OBO token exchange |
| Identity provider | External OIDC (Cognito default; Okta / Entra / IBM Verify pluggable) |
| Secrets / authorization | HashiCorp Vault Enterprise (self-hosted on AWS) — JWT auth, Agent Registry, dynamic secrets |
| Audit | Single hash-chained Vault audit log |
| Protected resources | RDS PostgreSQL, Bedrock KB, AWS IAM/STS |

---

## Required licenses (must obtain before deploy)

**HashiCorp Vault Enterprise license** — required for the Agent Registry (beta). Provided by Oscar/content team, injected at deploy time from a content-team-owned secret (e.g. Secrets Manager). Attendees do **not** bring their own license. See `workshop/content/20-prerequisites/`.

> There is no IVIA/IBM licensing in this edition — that whole dependency is removed.

---

## Quick start

**To recreate the proven phases (Stages 0-2) right now**, follow **`docs/RUNBOOK.md`** —
it has the exact, tested commands (AgentCore Node CLI, real paths, the gotchas and their
fixes). Start there.

**To pick up Stage 3 (real Vault Enterprise)**, see **`docs/VAULT_HANDOFF.md`** — what
Vault must provide and how the agent connects to it.

> The tiered `infrastructure/scripts/deploy-workshop.sh --tier N` flow below describes the
> *eventual packaged workshop* and is **not built yet** — those scripts are skeletons. The
> working, proven path today is the staged build in `docs/RUNBOOK.md`.

```bash
# EVENTUAL packaged flow (skeleton — not yet functional):
bash infrastructure/scripts/deploy-workshop.sh --tier 1   # foundation
bash infrastructure/scripts/deploy-workshop.sh --tier 2   # Vault Enterprise + config
bash infrastructure/scripts/deploy-workshop.sh --tier 3   # AgentCore + OIDC IdP
```

Proven work used the AgentCore Node CLI (`agentcore create/deploy/invoke`) with
`--profile agenticvault`, per stage. See `docs/RUNBOOK.md`.

---

## Version pinning (read before you deploy)

The Vault **Agent Registry is beta** and the AgentCore OBO API surface is still moving. This workshop is validated only against pinned versions. See the **"Tested against"** block in `docs/DESIGN.md` §7 and the version constants in `infrastructure/variables.tf` / `applications/*/requirements.txt`. Do not float to `latest`.
