#!/usr/bin/env bash
set -euo pipefail
echo "[check] aws sts get-caller-identity --profile agentic"
aws sts get-caller-identity --profile agentic >/dev/null || { echo "AWS auth failed" >&2; exit 1; }
echo "TODO: check terraform >= 1.10, bedrock-agentcore SDK pin, Bedrock model access, Vault Enterprise license secret"
