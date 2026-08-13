> ⚠️ **STUB** — this module is a design reference, not functional Terraform. See `infrastructure/README.md`.

# Module: agentcore_identity

**NEW.** AgentCore Identity: per-agent workload identity (ARN), user-context JWT
issuance, and the JWKS endpoint Vault trusts. Replaces IVIA as the token issuer
and Vault's Kubernetes auth method.

**UC1:** provisions the UC1 agent workload identity and exposes the issuer +
JWKS URL that `vault_config` consumes for its OAuth resource server profile.

**Note:** AgentCore control-plane resources are bootstrapped via
`aws bedrock-agentcore-control ... --profile agentic` where native Terraform
support does not yet exist (null_resource placeholders mark those spots). Pin the
`bedrock-agentcore` surface — see `../../../docs/DESIGN.md` section 7.

**Status:** new (replaces modules/verify_access as issuer).
