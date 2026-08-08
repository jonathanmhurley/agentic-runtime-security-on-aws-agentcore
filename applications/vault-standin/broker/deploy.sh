#!/usr/bin/env bash
# Deploy the Stage 2 credential broker: scoped role (vended) + Lambda + function URL.
# All AWS CLI calls use --profile agenticvault, region us-east-1.
# ACCOUNT is derived at runtime from STS (no hardcoded account id).
#
# Prereqs:
#   - tools/keygen.sh has been run and jwks.json published to a raw URL (JWKS_URL below)
#   - the Stage 1 KB exists (QLKOTZM2GC) — the vended role is scoped to bedrock:Retrieve on it
#
# Usage:
#   JWKS_URL="https://raw.githubusercontent.com/<you>/<repo>/main/jwks.json" \
#   ISS="<same base as mint-jwt --iss>" \
#   bash broker/deploy.sh
set -euo pipefail
PROFILE=agenticvault
REGION=us-east-1
ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
KB_ID="${KB_ID:-QLKOTZM2GC}"
FN=stage2-cred-broker
VENDED_ROLE=Stage2VendedKBReadRole
LAMBDA_ROLE=Stage2BrokerLambdaRole
AUD="${AUD:-vault-standin}"
ALLOWED_SUBS="${ALLOWED_SUBS:-uc1-agent}"
: "${JWKS_URL:?set JWKS_URL to your published jwks.json raw URL}"
: "${ISS:?set ISS to the issuer you mint tokens with}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[broker] identity (expect $ACCOUNT)"; aws sts get-caller-identity --profile "$PROFILE" --query Account --output text

# 1. Lambda execution role FIRST — the vended role's trust policy names it as
#    principal, and AWS rejects a trust policy referencing a non-existent principal.
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${LAMBDA_ROLE}"
LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$LAMBDA_ROLE" --profile "$PROFILE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE" --profile "$PROFILE" --assume-role-policy-document "$LAMBDA_TRUST"
fi
VENDED_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${VENDED_ROLE}"
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --profile "$PROFILE" --policy-name broker-perms \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[\
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${REGION}:${ACCOUNT}:*\"},\
    {\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Resource\":\"${VENDED_ROLE_ARN}\"}]}"

# 2. Vended role — what the broker hands out. Scoped to bedrock:Retrieve on the one KB.
#    Trust policy names the Lambda role (now exists). Retry briefly for IAM propagation.
VEND_TRUST="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"${LAMBDA_ROLE_ARN}\"},\"Action\":\"sts:AssumeRole\"}]}"
if ! aws iam get-role --role-name "$VENDED_ROLE" --profile "$PROFILE" >/dev/null 2>&1; then
  for attempt in 1 2 3 4 5; do
    if aws iam create-role --role-name "$VENDED_ROLE" --profile "$PROFILE" --assume-role-policy-document "$VEND_TRUST" 2>/dev/null; then
      break
    fi
    echo "[broker] vended-role create retry $attempt (waiting for Lambda role to propagate)"; sleep 5
  done
else
  aws iam update-assume-role-policy --role-name "$VENDED_ROLE" --profile "$PROFILE" --policy-document "$VEND_TRUST"
fi
aws iam put-role-policy --role-name "$VENDED_ROLE" --profile "$PROFILE" \
  --policy-name kb-read --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"bedrock:Retrieve\"],\"Resource\":\"arn:aws:bedrock:${REGION}:${ACCOUNT}:knowledge-base/${KB_ID}\"}]}"
echo "[broker] waiting 10s for role propagation"; sleep 10

# 3. Package the Lambda (handler + vendored deps).
BUILD="$HERE/build"; rm -rf "$BUILD"; mkdir -p "$BUILD"
# Fetch LINUX x86_64 wheels for the Lambda runtime (python3.12), NOT the host
# platform. cryptography/cffi ship native binaries; a macOS wheel yields
# "invalid ELF header" at import on Lambda. --platform + --only-binary pins it.
python3 -m pip install -r "$HERE/requirements.txt" -t "$BUILD" --quiet \
  --platform manylinux2014_x86_64 --python-version 3.12 --implementation cp \
  --only-binary=:all: --upgrade
cp "$HERE/handler.py" "$BUILD/"
( cd "$BUILD" && zip -qr ../broker.zip . )
ZIP="$HERE/broker.zip"

# 4. Create/update the function.
ENVVARS="Variables={JWKS_URL=$JWKS_URL,EXPECTED_ISS=$ISS,EXPECTED_AUD=$AUD,SCOPED_ROLE_ARN=$VENDED_ROLE_ARN,ALLOWED_SUBS=$ALLOWED_SUBS,CRED_TTL_SECONDS=900}"
if aws lambda get-function --function-name "$FN" --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --profile "$PROFILE" --region "$REGION" --zip-file "fileb://$ZIP" >/dev/null
  # Wait for the code update to finish before the config update — otherwise the
  # second call races the first and fails with ResourceConflictException.
  aws lambda wait function-updated --function-name "$FN" --profile "$PROFILE" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --environment "$ENVVARS" --handler handler.handler --runtime python3.12 --timeout 15 >/dev/null
else
  aws lambda create-function --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --runtime python3.12 --handler handler.handler --timeout 15 \
    --role "$LAMBDA_ROLE_ARN" --zip-file "fileb://$ZIP" --environment "$ENVVARS" >/dev/null
fi

# 5. Function URL with AuthType NONE. AUTHORIZATION IS THE JWT, not AWS SigV4.
# This is deliberate and more faithful to the Vault model: Vault authorizes a
# request on the presented JWT (validated via JWKS) + the allowlist, NOT on AWS
# IAM. An AWS_IAM Function URL added an orthogonal transport-auth layer that the
# AgentCore Runtime's outbound signer did not satisfy (403 before the function
# ran), which is incidental to what this stand-in demonstrates. With NONE, the
# broker's own JWKS-validation + allowlist ARE the access control — exactly the
# control we are proving. The vended creds remain tightly scoped (bedrock:Retrieve
# on one KB), so an unauthenticated caller with no valid JWT gets a 401/403 from
# the broker logic itself and never receives credentials.
aws lambda create-function-url-config --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
  --auth-type NONE >/dev/null 2>&1 || \
  aws lambda update-function-url-config --function-name "$FN" --profile "$PROFILE" --region "$REGION" \
    --auth-type NONE >/dev/null
# Public invoke permission (AuthType NONE still needs a resource permission allowing
# lambda:InvokeFunctionUrl with FunctionUrlAuthType=NONE).
aws lambda remove-permission --function-name "$FN" --statement-id public-invoke-url \
  --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1 || true
aws lambda add-permission --function-name "$FN" --statement-id public-invoke-url \
  --action lambda:InvokeFunctionUrl --principal "*" \
  --function-url-auth-type NONE --profile "$PROFILE" --region "$REGION" >/dev/null
URL="$(aws lambda get-function-url-config --function-name "$FN" --profile "$PROFILE" --region "$REGION" --query FunctionUrl --output text)"

# 6. Grant the AGENT execution role lambda:InvokeFunction on the broker. This is
# the transport auth for the DIRECT lambda.invoke path the agent uses (the Function
# URL above is retained but not used by the agent — direct invoke sidesteps the
# Function-URL HTTP-auth layer the AgentCore runtime could not satisfy).
AGENT_EXEC_ROLE="${AGENT_EXEC_ROLE:-AgentCore-stage0hello-def-ApplicationAgentStage0hel-sV2ZNvKgNJNS}"
aws iam put-role-policy --role-name "$AGENT_EXEC_ROLE" --profile "$PROFILE" \
  --policy-name stage2-invoke-broker-fn \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"lambda:InvokeFunction\"],\"Resource\":\"arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN}\"}]}" \
  2>/dev/null && echo "[broker] granted ${AGENT_EXEC_ROLE} lambda:InvokeFunction on ${FN}" || echo "[broker] (invoke grant skipped — set AGENT_EXEC_ROLE if the agent role name differs)"

cat <<EOF

============================================================
  Stage 2 broker deployed.
    Function:      $FN
    Broker URL:    $URL
    Vended role:   $VENDED_ROLE_ARN  (bedrock:Retrieve on KB $KB_ID)
    Allowlist:     $ALLOWED_SUBS
    Trusts JWKS:   $JWKS_URL
  Next:
    1. Set BROKER_URL on the agent runtime (or the _DEFAULT_BROKER_URL in code).
    2. Grant the agent execution role lambda:InvokeFunctionUrl on this function.
    3. Mint a JWT (tools/mint-jwt.py) and invoke the agent.
============================================================
EOF
