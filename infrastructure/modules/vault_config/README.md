# Module: vault_config

Vault auth + secrets configuration for the AgentCore edition.

**UC1 slice — implemented:**
- `vault_audit` (file -> stdout, JSON) — single hash-chained audit stream.
- `vault_oauth_resource_server_config_profile.agentcore` — validates AgentCore
  Identity JWTs directly via `X-Vault-Token` against the AgentCore JWKS endpoint.
  Replaces the retired Kubernetes auth method.
- PostgreSQL secrets engine + `uc1-readonly` role (SELECT-only, TTL 15m).
- AWS secrets engine + `aws/sts/bedrock-reader` (scoped Bedrock STS for the KB).
- `vault_policy.uc1` + `vault_agent_registration.uc1` (Agent Registry, beta).

**Provider pin:** `hashicorp/vault >= 5.10.1, < 6.0.0` — first release exposing
`vault_oauth_resource_server_config_profile` + `vault_agent_registration`.
Carried forward from the EKS repo. See `../../../docs/DESIGN.md` section 7.

**TODO (UC2/UC3 slices):** per-user OBO read role (`uc2-personal-readonly`),
refund-writer role + RAR-mandatory registration (`optional_authorization_details = false`).

**Status:** stays (JWT auth retargeted to AgentCore JWKS; k8s auth removed).
