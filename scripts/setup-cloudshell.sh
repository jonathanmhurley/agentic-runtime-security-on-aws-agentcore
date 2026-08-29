#!/usr/bin/env bash
# setup-cloudshell.sh — one-time CloudShell setup for the workshop.
# Run from the repo root: bash scripts/setup-cloudshell.sh
#
# Installs: AgentCore CLI, uv, aws-targets.json for the stage0hello agent.
# Idempotent — safe to re-run after a CloudShell timeout.
set -euo pipefail

echo "=== Workshop CloudShell Setup ==="

# 1. AgentCore CLI (npm global to /tmp — CloudShell home is ~1GB)
echo "[1/4] Installing AgentCore CLI..."
rm -rf ~/.npm/_cacache 2>/dev/null || true
export NPM_CONFIG_PREFIX=/tmp/npm-global
export PATH="/tmp/npm-global/bin:$PATH"
npm install -g @aws/agentcore --silent 2>/dev/null
echo "  agentcore $(agentcore --version)"

# 2. uv (Python package manager — used by agentcore deploy)
echo "[2/4] Installing uv..."
if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null
fi
export PATH="$HOME/.local/bin:$PATH"
echo "  $(uv --version)"

# 2b. PyJWT (used by mint-jwt.py for signing workshop tokens)
pip3 install pyjwt --quiet 2>/dev/null
echo "  pyjwt $(python3 -c 'import jwt; print(jwt.__version__)' 2>/dev/null || echo 'installed')"

# 3. Vault CLI (best-effort — CloudShell home may be too small)
echo "[3/5] Installing Vault CLI..."
if ! command -v vault &>/dev/null; then
  curl -fsSL https://releases.hashicorp.com/vault/1.18.4/vault_1.18.4_linux_amd64.zip -o /tmp/vault.zip 2>/dev/null
  cd /tmp && unzip -oq vault.zip 2>/dev/null && mkdir -p /tmp/npm-global/bin && mv vault /tmp/npm-global/bin/ 2>/dev/null && cd - >/dev/null || true
fi
if command -v vault &>/dev/null; then
  echo "  $(vault --version 2>/dev/null || echo 'installed but may not run — use curl for Vault API calls')"
else
  echo "  skipped (disk full) — use curl for Vault API calls"
fi

# 4. PATH persistence for this session
echo "[4/5] Updating PATH..."
export PATH="/tmp/npm-global/bin:$HOME/.local/bin:$PATH"

# 5. aws-targets.json for stage0hello
echo "[5/5] Creating aws-targets.json..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1

for proj in applications/stage0hello; do
  mkdir -p "$proj/agentcore"
  cat > "$proj/agentcore/aws-targets.json" << EOF
[{"name":"default","description":"Workshop target","account":"${ACCOUNT_ID}","region":"${REGION}"}]
EOF
  echo "  $proj → account $ACCOUNT_ID, region $REGION"
done

echo ""
echo "=== Setup complete ==="
echo "  Account: $ACCOUNT_ID"
echo "  Region:  $REGION"
echo ""
echo "  IMPORTANT: Run this in your current shell to update PATH:"
echo "    export PATH=\"/tmp/npm-global/bin:\$HOME/.local/bin:\$PATH\""
echo ""
echo "  Or re-source by running:"
echo "    source <(echo 'export PATH=\"/tmp/npm-global/bin:\$HOME/.local/bin:\$PATH\"')"
echo ""
echo "  Next: cd applications/stage0hello && agentcore deploy"
