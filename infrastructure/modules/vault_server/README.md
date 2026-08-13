> ⚠️ **STUB** — this module is a design reference, not functional Terraform. See `infrastructure/README.md`.

# Module: vault_server

Self-hosted **Vault Enterprise** on AWS. Single persistent server on EC2 (or Fargate) — NOT an HA Raft cluster (adequate for a lab, keeps the deploy light). Enterprise license injected at deploy from a content-team-owned secret (e.g. Secrets Manager). Pin the Vault Enterprise version (see DESIGN §7).

**Status:** stays (retargeted from EKS-hosted to self-hosted on AWS).
