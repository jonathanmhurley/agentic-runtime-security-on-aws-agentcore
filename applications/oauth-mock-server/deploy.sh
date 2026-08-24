#!/usr/bin/env bash
# Deploy the UC2 OAuth mock token server.
# Issues user-identity JWTs for the AgentCore OBO exchange.
#
# Creates a Function URL (AuthType: NONE) so AgentCore can POST to /token.
# The handler validates client credentials (CLIENT_SECRET_BASIC) at the
# application layer — this is the standard OAuth pattern for token endpoints.
#
# NOTE: If your account has an org SCP blocking AuthType: NONE Function URLs
# (e.g. internal Amazon accounts), use deploy-dev.sh instead — it adds an
# API Gateway HTTP API as an alternative public endpoint.
set -euo pipefail
PROFILE="${AWS_PROFILE:-agenticvault}"
REGION=us-east-1
ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
FN=oauth-mock-server
LAMBDA_ROLE=OAuthMockServerRole
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_STANDIN="$HERE/../vault-standin"

# Client credentials for the OAuth token endpoint (AgentCore presents these)
CLIENT_ID="workshop-obo-client"
CLIENT_SECRET=[REDACTED_PASSWORD]

echo "[oauth-mock] account: $ACCOUNT"

# 1. Lambda execution role (minimal — just logs)
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$LAMBDA_ROLE" --profile "$PROFILE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE" --profile "$PROFILE" --assume-role-policy-document "$LAMBDA_TRUST"
fi
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --profile "$PROFILE" --policy-name logs \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${REGION}:${ACCOUNT}:*\"}]}"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${LAMBDA_ROLE}"
sleep 10

# 2. Package (handler + private key + pyjwt)
BUILD="$HERE/build"; rm -rf "$BUILD"; mkdir -p "$BUILD"
cp "$HERE/handler.py" "$BUILD/"
cp "$VAULT_STANDIN/private.pem" "$BUILD/"
python3 -m pip install pyjwt cryptography -t "$BUILD" --quiet \
  --platform manylinux2014_x86_64 --python-version 3.12 --implementation cp --only-binary=:all: --upgrade
( cd "$BUILD" && zip -qr ../mock-server.zip . )
ZIP="$HERE/mock-server.zip"

# 3. Build env vars JSON
_build_env_json() {
  local token_endpoint="${1:-}"
  cat <<ENDJSON
{"Variables":{"ISSUER":"https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin","KID":"stage2-key-1","AUDIENCE":"vault-standin","AGENT_SUB":"uc1-agent","TOKEN_TTL":"900","CLIENT_ID":"${CLIENT_ID}","CLIENT_SECRET":"${CLIENT_SECRET}","TOKEN_ENDPOINT":"${token_endpoint}"}}
ENDJSON
}

ENVJSON=$(_build_env_json "")

# 4. Create/update Lambda
if aws lambda get-function --function-name "$FN" --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --profile "$PROFILE" --region "$REGION" --zip-file "fileb://$ZIP" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --profile "$PROFILE" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --environment "$ENVJSON" --handler handler.handler --runtime python3.12 --timeout 15 >/dev/null
else
  aws lambda create-function --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --runtime python3.12 --handler handler.handler --timeout 15 \
    --role "$LAMBDA_ROLE_ARN" --zip-file "fileb://$ZIP" --environment "$ENVJSON" >/dev/null
fi
aws lambda wait function-updated --function-name "$FN" --profile "$PROFILE" --region "$REGION"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}"

# 5. Function URL (AuthType: NONE — application-layer client auth in the handler)
FURL=$(aws lambda get-function-url-config --function-name "$FN" --profile "$PROFILE" --region "$REGION" --query 'FunctionUrl' --output text 2>/dev/null || echo "")
if [ -z "$FURL" ] || [ "$FURL" = "None" ]; then
  FURL=$(aws lambda create-function-url-config --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --auth-type NONE --query 'FunctionUrl' --output text)
  # Allow public invoke (required for AuthType: NONE)
  aws lambda add-permission --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --statement-id FunctionURLAllowPublicAccess \
    --action lambda:InvokeFunctionUrl \
    --principal "*" \
    --function-url-auth-type NONE 2>/dev/null || true
fi

# Remove trailing slash for cleaner URL construction
FURL="${FURL%/}"

# 6. Update TOKEN_ENDPOINT env var now that we know the Function URL
ENVJSON=$(_build_env_json "${FURL}/token")
aws lambda wait function-updated --function-name "$FN" --profile "$PROFILE" --region "$REGION"
aws lambda update-function-configuration --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
  --environment "$ENVJSON" >/dev/null

echo
echo "============================================================"
echo "  OAuth Mock Server deployed."
echo "    Function: $FN ($LAMBDA_ARN)"
echo "    Function URL: $FURL"
echo "    Token endpoint: ${FURL}/token"
echo "    Discovery: ${FURL}/.well-known/openid-configuration"
echo "    Client ID: $CLIENT_ID"
echo "    Issuer: same as workshop JWKS issuer"
echo ""
echo "  Test (Function URL, OAuth grant):"
echo "    curl -s -X POST ${FURL}/token \\"
echo "      -u '${CLIENT_ID}:${CLIENT_SECRET}' \\"
echo "      -d 'grant_type=client_credentials' | python3 -m json.tool"
echo ""
echo "  Test (direct invoke, Phase A compat):"
echo "    aws lambda invoke --function-name $FN --payload '{\"username\":\"alice@example.com\"}' /tmp/token.json --profile $PROFILE --region $REGION"
echo ""
echo "  Register with AgentCore (Phase B):"
echo "    aws bedrock-agentcore-control create-oauth2-credential-provider \\"
echo "      --profile $PROFILE --region $REGION \\"
echo "      --cli-input-json '{"
echo "      \"name\": \"workshop-obo-vault\","
echo "      \"credentialProviderVendor\": \"CustomOauth2\","
echo "      \"oauth2ProviderConfigInput\": {"
echo "        \"customOauth2ProviderConfig\": {"
echo "          \"oauthDiscovery\": { \"discoveryUrl\": \"${FURL}/.well-known/openid-configuration\" },"
echo "          \"clientId\": \"${CLIENT_ID}\","
echo "          \"clientSecret\": \"${CLIENT_SECRET}\","
echo "          \"clientAuthenticationMethod\": \"CLIENT_SECRET_BASIC\","
echo "          \"onBehalfOfTokenExchangeConfig\": { \"grantType\": \"JWT_AUTHORIZATION_GRANT\" }"
echo "        }"
echo "      }"
echo "    }'"
echo ""
echo "  NOTE: If Function URL returns 403 (org SCP), run deploy-dev.sh for an"
echo "  API Gateway alternative."
echo "============================================================"
