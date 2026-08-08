# Infrastructure

Three Terraform roots deployed in order by `scripts/deploy-workshop.sh --tier <n>`:

- root (`.`) - Tier 1 foundation
- `services/` - Tier 2 Vault Enterprise + vault-config
- `workloads/` - Tier 3 AgentCore + OIDC IdP

Modules under `modules/`. See `../docs/DESIGN.md` for stays/changes/drops.
