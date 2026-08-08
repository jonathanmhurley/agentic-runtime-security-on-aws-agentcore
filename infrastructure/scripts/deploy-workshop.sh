#!/usr/bin/env bash
# Tiered, idempotent deploy for the AgentCore edition.
#   Tier 1: foundation (VPC-slim, RDS, Bedrock KB, IAM, audit, Vault IAM/KMS)
#   Tier 2: Vault Enterprise server + vault-config (JWT auth vs AgentCore JWKS, secrets, Agent Registry)
#   Tier 3: AgentCore (Runtime agents, Identity, OBO credential provider) + OIDC IdP (Cognito)
# All AWS CLI calls use --profile agentic. Safe to re-run end-to-end.
set -euo pipefail
TIER=""
while [[ $# -gt 0 ]]; do case "$1" in --tier) TIER="$2"; shift 2;; *) echo "unknown arg: $1" >&2; exit 1;; esac; done
[[ -z "$TIER" ]] && { echo "usage: deploy-workshop.sh --tier <1|2|3>" >&2; exit 1; }
echo "[deploy] tier $TIER (profile: agentic)"
case "$TIER" in
  1) echo "TODO: terraform apply infrastructure/ (foundation)";;
  2) echo "TODO: terraform apply infrastructure/services/ (Vault Enterprise + vault-config)";;
  3) echo "TODO: terraform apply infrastructure/workloads/ (AgentCore + OIDC IdP); configure OBO provider";;
  *) echo "invalid tier: $TIER" >&2; exit 1;;
esac
