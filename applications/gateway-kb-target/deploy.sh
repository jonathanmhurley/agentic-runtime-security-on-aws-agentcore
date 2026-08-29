#!/usr/bin/env bash
# Deploy the Gateway KB target Lambda + register it on the Gateway.
# AWS CLI calls use --profile $AWS_PROFILE if set; otherwise default credentials. region us-east-1.
set -euo pipefail
PROFILE="${AWS_PROFILE:-}"
REGION=us-east-1
ACCOUNT="$(aws sts get-caller-identity ${PROFILE:+--profile "$PROFILE"} --query Account --output text)"
FN=gateway-kb-target
KB_ID="${KB_ID:-QLKOTZM2GC}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-discover Gateway ID from deployed-state.json or list-gateways API
if [ -z "${GATEWAY_ID:-}" ]; then
  STATE_FILE="$HERE/../stage0hello/agentcore/deployed-state.json"
  if [ -f "$STATE_FILE" ]; then
    GATEWAY_ID=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print([g['gatewayId'] for g in d.get('gateways',{}).values()][0])" 2>/dev/null || true)
  fi
  if [ -z "${GATEWAY_ID:-}" ]; then
    GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --query "gateways[?contains(gatewayName,'workshop-gateway')].gatewayId | [0]" --output text 2>/dev/null || echo "")
  fi
  [ -z "${GATEWAY_ID:-}" ] && { echo "[gateway-kb-target] ERROR: Could not discover Gateway ID. Set GATEWAY_ID env var."; exit 1; }
fi

TARGET_NAME="kb-retrieve"
LAMBDA_ROLE=GatewayKBTargetRole

echo "[gateway-kb-target] account: $ACCOUNT"

# 1. Lambda execution role (bedrock:Retrieve on the KB)
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$LAMBDA_ROLE" ${PROFILE:+--profile "$PROFILE"} >/dev/null 2>&1; then
  echo "[gateway-kb-target] creating role $LAMBDA_ROLE"
  aws iam create-role --role-name "$LAMBDA_ROLE" ${PROFILE:+--profile "$PROFILE"} --assume-role-policy-document "$LAMBDA_TRUST"
fi
aws iam put-role-policy --role-name "$LAMBDA_ROLE" ${PROFILE:+--profile "$PROFILE"} \
  --policy-name kb-retrieve \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[\
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${REGION}:${ACCOUNT}:*\"},\
    {\"Effect\":\"Allow\",\"Action\":[\"bedrock:Retrieve\"],\"Resource\":\"arn:aws:bedrock:${REGION}:${ACCOUNT}:knowledge-base/${KB_ID}\"}]}"
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${LAMBDA_ROLE}"
echo "[gateway-kb-target] role: $LAMBDA_ROLE_ARN"
sleep 10

# 2. Package + deploy the Lambda
BUILD="$HERE/build"; rm -rf "$BUILD"; mkdir -p "$BUILD"
cp "$HERE/handler.py" "$BUILD/"
( cd "$BUILD" && zip -qr ../target.zip . )
ZIP="$HERE/target.zip"

ENVVARS="Variables={BEDROCK_KB_ID=$KB_ID,AWS_REGION_OVERRIDE=$REGION}"
if aws lambda get-function --function-name "$FN" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --zip-file "fileb://$ZIP" >/dev/null
  aws lambda wait function-updated --function-name "$FN" ${PROFILE:+--profile "$PROFILE"} --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
    --environment "$ENVVARS" --handler handler.handler --runtime python3.12 --timeout 15 >/dev/null
else
  aws lambda create-function --function-name "$FN" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
    --runtime python3.12 --handler handler.handler --timeout 15 \
    --role "$LAMBDA_ROLE_ARN" --zip-file "fileb://$ZIP" --environment "$ENVVARS" >/dev/null
fi
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}"
echo "[gateway-kb-target] lambda: $LAMBDA_ARN"

# 3. Grant the GATEWAY role permission to invoke this Lambda
# The Gateway's IAM role (from the CDK stack) needs lambda:InvokeFunction on this target.
# Get the Gateway role from the Gateway config:
GW_ROLE="$(aws bedrock-agentcore-control get-gateway --gateway-identifier "$GATEWAY_ID" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --query roleArn --output text 2>/dev/null || echo "")"
if [ -n "$GW_ROLE" ] && [ "$GW_ROLE" != "None" ]; then
  GW_ROLE_NAME="$(echo "$GW_ROLE" | sed 's|.*/||')"
  aws iam put-role-policy --role-name "$GW_ROLE_NAME" ${PROFILE:+--profile "$PROFILE"} \
    --policy-name invoke-kb-target \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"lambda:InvokeFunction\"],\"Resource\":\"${LAMBDA_ARN}\"}]}"
  echo "[gateway-kb-target] granted $GW_ROLE_NAME -> lambda:InvokeFunction on $FN"
else
  echo "[gateway-kb-target] WARNING: could not determine Gateway role; grant lambda:InvokeFunction manually"
fi

# 4. Register as a Gateway target
echo "[gateway-kb-target] adding target to gateway $GATEWAY_ID"
aws bedrock-agentcore-control create-gateway-target \
  --gateway-identifier "$GATEWAY_ID" \
  --name "$TARGET_NAME" \
  --description "Retrieve passages from the Meridian Knowledge Base" \
  ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
  --target-configuration "{
    \"mcp\": {
      \"lambda\": {
        \"lambdaArn\": \"${LAMBDA_ARN}\",
        \"toolSchema\": {
          \"inlinePayload\": [
            {
              \"name\": \"retrieve_from_kb\",
              \"description\": \"Retrieve relevant passages from the Meridian Knowledge Base given a natural language query.\",
              \"inputSchema\": {
                \"type\": \"object\",
                \"properties\": {
                  \"query\": {
                    \"type\": \"string\",
                    \"description\": \"The question to search the knowledge base for.\"
                  }
                },
                \"required\": [\"query\"]
              }
            }
          ]
        }
      }
    }
  }" \
  --credential-provider-configurations "[{\"credentialProviderType\": \"GATEWAY_IAM_ROLE\"}]" \
  2>&1 | tee /tmp/gw-target-output.json

echo
echo "============================================================"
echo "  Gateway KB target deployed."
echo "    Lambda:   $FN ($LAMBDA_ARN)"
echo "    Target:   $TARGET_NAME on gateway $GATEWAY_ID"
echo "    Tool:     retrieve_from_kb (query -> passages)"
echo "  Next: mint a JWT and call tools/call via the Gateway."
echo "============================================================"
