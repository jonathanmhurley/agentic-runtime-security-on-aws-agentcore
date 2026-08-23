#!/usr/bin/env bash
# Deploy the UC2 OAuth mock token server.
# Issues user-identity JWTs for the AgentCore OBO exchange.
set -euo pipefail
PROFILE="${AWS_PROFILE:-agenticvault}"
REGION=us-east-1
ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
FN=oauth-mock-server
LAMBDA_ROLE=OAuthMockServerRole
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_STANDIN="$HERE/../vault-standin"

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

# 3. Create/update Lambda
ENVVARS="Variables={ISSUER=https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin,KID=stage2-key-1,AUDIENCE=vault-standin,AGENT_SUB=uc1-agent,TOKEN_TTL=900}"
if aws lambda get-function --function-name "$FN" --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --profile "$PROFILE" --region "$REGION" --zip-file "fileb://$ZIP" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --profile "$PROFILE" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --environment "$ENVVARS" --handler handler.handler --runtime python3.12 --timeout 15 >/dev/null
else
  aws lambda create-function --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --runtime python3.12 --handler handler.handler --timeout 15 \
    --role "$LAMBDA_ROLE_ARN" --zip-file "fileb://$ZIP" --environment "$ENVVARS" >/dev/null
fi
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}"

echo
echo "============================================================"
echo "  OAuth Mock Server deployed."
echo "    Function: $FN ($LAMBDA_ARN)"
echo "    Issuer:   same as workshop JWKS issuer"
echo "  Usage (via lambda.invoke):"
echo "    aws lambda invoke --function-name $FN --payload \'{"username":"alice@example.com"}\' /tmp/token.json"
echo "    cat /tmp/token.json | python3 -m json.tool"
echo "============================================================"
