#!/usr/bin/env bash
# deploy-dev.sh — adds an API Gateway HTTP API on top of deploy.sh
#
# Use this instead of deploy.sh when your account has an org SCP that blocks
# Lambda Function URLs with AuthType: NONE (e.g. internal Amazon accounts).
# API Gateway HTTP APIs are not affected by that SCP.
#
# This script:
# 1. Runs deploy.sh (deploys Lambda + Function URL as normal)
# 2. Creates an API Gateway HTTP API as an alternative public endpoint
# 3. Updates the Lambda's TOKEN_ENDPOINT env var to point at the APIGW URL
set -euo pipefail
PROFILE="${AWS_PROFILE:-}"
REGION=us-east-1
ACCOUNT="$(aws sts get-caller-identity ${PROFILE:+--profile "$PROFILE"} --query Account --output text)"
FN=oauth-mock-server
API_NAME=oauth-mock-api
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLIENT_ID="workshop-obo-client"
CLIENT_SECRET=[REDACTED_PASSWORD]

# 1. Run the base deploy (creates Lambda + Function URL)
bash "$HERE/deploy.sh"
echo ""

# 2. API Gateway HTTP API
echo "[oauth-mock-dev] Setting up API Gateway (SCP workaround)..."
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}"

API_ID=$(aws apigatewayv2 get-apis ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || echo "None")

if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  API_ID=$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
    ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --query 'ApiId' --output text)

  # Lambda proxy integration (payload format 2.0 = same as Function URL event shape)
  INTEGRATION_ID=$(aws apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$LAMBDA_ARN" \
    --payload-format-version "2.0" \
    ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --query 'IntegrationId' --output text)

  # Default catch-all route
  aws apigatewayv2 create-route --api-id "$API_ID" \
    --route-key '$default' \
    --target "integrations/${INTEGRATION_ID}" \
    ${PROFILE:+--profile "$PROFILE"} --region "$REGION" >/dev/null

  # Auto-deploy stage
  aws apigatewayv2 create-stage --api-id "$API_ID" \
    --stage-name '$default' --auto-deploy \
    ${PROFILE:+--profile "$PROFILE"} --region "$REGION" >/dev/null

  # Grant API Gateway permission to invoke the Lambda
  aws lambda add-permission --function-name "$FN" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
    --statement-id ApiGatewayInvoke \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*" 2>/dev/null || true

  echo "[oauth-mock-dev] API Gateway created: $API_ID"
else
  echo "[oauth-mock-dev] API Gateway already exists: $API_ID"
fi

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"

# 3. Update TOKEN_ENDPOINT to APIGW URL
_build_env_json() {
  local token_endpoint="${1:-}"
  cat <<ENDJSON
{"Variables":{"ISSUER":"https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin","KID":"stage2-key-1","AUDIENCE":"vault-standin","AGENT_SUB":"uc1-agent","TOKEN_TTL":"900","CLIENT_ID":"${CLIENT_ID}","CLIENT_SECRET":"${CLIENT_SECRET}","TOKEN_ENDPOINT":"${token_endpoint}"}}
ENDJSON
}

ENVJSON=$(_build_env_json "${API_URL}/token")
aws lambda wait function-updated --function-name "$FN" ${PROFILE:+--profile "$PROFILE"} --region "$REGION"
aws lambda update-function-configuration --function-name "$FN" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
  --environment "$ENVJSON" >/dev/null

echo ""
echo "============================================================"
echo "  API Gateway endpoint (use this instead of Function URL):"
echo "    API URL: $API_URL"
echo "    Token endpoint: ${API_URL}/token"
echo "    Discovery: ${API_URL}/.well-known/openid-configuration"
echo ""
echo "  Test:"
echo "    curl -s -X POST ${API_URL}/token \\"
echo "      -u '${CLIENT_ID}:${CLIENT_SECRET}' \\"
echo "      -d 'grant_type=client_credentials' | python3 -m json.tool"
echo ""
echo "  Register with AgentCore (Phase B):"
echo "    aws bedrock-agentcore-control create-oauth2-credential-provider \\"
echo "      ${PROFILE:+--profile $PROFILE} --region $REGION \\"
echo "      --cli-input-json '{"
echo "      \"name\": \"workshop-obo-vault\","
echo "      \"credentialProviderVendor\": \"CustomOauth2\","
echo "      \"oauth2ProviderConfigInput\": {"
echo "        \"customOauth2ProviderConfig\": {"
echo "          \"oauthDiscovery\": { \"discoveryUrl\": \"${API_URL}/.well-known/openid-configuration\" },"
echo "          \"clientId\": \"${CLIENT_ID}\","
echo "          \"clientSecret\": \"${CLIENT_SECRET}\","
echo "          \"clientAuthenticationMethod\": \"CLIENT_SECRET_BASIC\","
echo "          \"onBehalfOfTokenExchangeConfig\": { \"grantType\": \"JWT_AUTHORIZATION_GRANT\" }"
echo "        }"
echo "      }"
echo "    }'"
echo "============================================================"
