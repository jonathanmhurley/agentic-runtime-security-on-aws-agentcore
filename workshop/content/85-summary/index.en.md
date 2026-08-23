---
title: 'Summary'
weight: 85
---

## What you proved

You deployed an agent on Amazon Bedrock AgentCore Runtime and demonstrated the
full agentic security pattern through two backends:

**AgentCore Gateway (native AWS):**
- JWT validated via OIDC discovery + JWKS (CUSTOM_JWT inbound auth)
- Gateway brokered scoped access to the KB target via its IAM role
- The caller never held `bedrock:Retrieve` directly

**HashiCorp Vault Enterprise (JWT auth + dynamic secrets):**
- Same JWT presented to Vault's JWT auth method
- Vault validated the signature (JWKS), checked the audience and `bound_subject`
- Vault vended short-lived STS credentials (15m TTL) via the AWS secrets engine
- Unregistered agents (`sub: not-registered`) were denied with a clear error

Both backends proved the same control objectives with the same JWT:
- **OBJ-1** — verifiable agent identity
- **OBJ-2** — no standing privileges (credentials are ephemeral)
- **OBJ-4** — enforcement at the point of use
- **OBJ-5** — audit trail (Gateway logs + Vault audit device)

## What's next

- **UC2:** User identity via OIDC + PKCE + AgentCore OBO (user-delegated access)
- **UC3:** Privileged write with Vault's single-plane audit correlation
- **OAuth Resource Server:** Vault's beta direct-presentation mode (no login step) +
  Agent Registry + RAR claims — for UC2/UC3 when the beta stabilizes
