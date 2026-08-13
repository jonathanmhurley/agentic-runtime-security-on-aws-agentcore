#!/usr/bin/env bash
# demo.sh — prove the AgentCore Gateway flow end-to-end in one command.
#
# Assumes infrastructure is deployed (Stage 0-1 + Gateway + KB target).
# Mints a JWT, calls the Gateway with it, and prints the KB answer.
#
# Usage:
#   bash demo.sh
#   bash demo.sh "What credit applies if a shipment is more than 24 hours late?"
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_STANDIN="$HERE/applications/vault-standin"
ISSUER="https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin"
QUERY="${1:-What is RapidLane same-day SLA?}"

# --- Discover Gateway URL from deployed state ---
PROFILE="${AWS_PROFILE:-agenticvault}"
REGION="${AWS_REGION:-us-east-1}"
if [ -z "${GATEWAY_URL:-}" ]; then
  DEPLOYED_STATE="$HERE/applications/stage0hello/agentcore/.cli/deployed-state.json"
  if [ -f "$DEPLOYED_STATE" ]; then
    GATEWAY_URL="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
for target in d.get('targets', {}).values():
    gws = target.get('resources', {}).get('mcp', {}).get('gateways', {})
    for gw in gws.values():
        url = gw.get('gatewayUrl', '')
        if url:
            print(url)
            sys.exit(0)
sys.exit(1)
" "$DEPLOYED_STATE" 2>/dev/null || echo "")"
  fi
  if [ -z "${GATEWAY_URL:-}" ]; then
    echo "ERROR: could not discover Gateway URL. Set GATEWAY_URL= or deploy a gateway first." >&2
    exit 1
  fi
fi

echo "=== AgentCore Gateway Demo ==="
echo "Gateway: $GATEWAY_URL"
echo "Query: $QUERY"
echo

# 1. Mint a JWT
JWT="$(python3 "$VAULT_STANDIN/tools/mint-jwt.py" --sub uc1-agent --aud vault-standin \
  --iss "$ISSUER" --scopes kb:read --kid stage2-key-1 --ttl 900 \
  --key "$VAULT_STANDIN/private.pem")"
echo "[1] JWT minted (sub=uc1-agent, aud=vault-standin, ttl=900s)"

# 2. Call the Gateway
echo "[2] Calling Gateway..."
RESPONSE="$(curl -s -X POST "$GATEWAY_URL/mcp" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"kb-retrieve___retrieve_from_kb\",\"arguments\":{\"query\":\"$QUERY\"}},\"id\":1}")"

# 3. Parse and display
echo "[3] Response:"
echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'error' in data:
    print('  ERROR:', data['error'].get('message', data['error']))
    sys.exit(1)
content = data.get('result', {}).get('content', [{}])
for c in content:
    text = c.get('text', '')
    try:
        body = json.loads(text)
        if 'body' in body:
            passages = json.loads(body['body']).get('passages', [])
            for p in passages[:2]:
                print('  ---')
                print(' ', p['text'][:300])
                score = p.get('score')
                if score is not None:
                    print('  [score: %.3f]' % score)
        else:
            print(' ', text[:500])
    except (json.JSONDecodeError, TypeError):
        print(' ', text[:500])
"
echo
echo "=== Flow: JWT -> Gateway CUSTOM_JWT inbound -> Lambda target GATEWAY_IAM_ROLE -> bedrock:Retrieve -> answer ==="
