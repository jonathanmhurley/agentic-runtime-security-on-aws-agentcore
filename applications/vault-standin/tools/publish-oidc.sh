#!/usr/bin/env bash
# Publish a static OIDC discovery document + JWKS to an S3 public bucket.
# This gives AgentCore Gateway a proper discoveryUrl (.well-known/openid-configuration)
# without standing up Cognito or any IdP. Same local keypair as Stage 2.
#
# Usage:
#   bash tools/publish-oidc.sh        # uses --profile $AWS_PROFILE (or default creds)
#
# After running, note the printed DISCOVERY_URL — that's what you pass
# to `agentcore add gateway --discovery-url <DISCOVERY_URL>`.
set -euo pipefail
PROFILE="${AWS_PROFILE:-}"
REGION=us-east-1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$HERE/.."
ACCOUNT="$(aws sts get-caller-identity ${PROFILE:+--profile "$PROFILE"} --query Account --output text)"
BUCKET="stage2-oidc-issuer-${ACCOUNT}"
ISSUER_BASE="https://${BUCKET}.s3.${REGION}.amazonaws.com"

echo "[publish-oidc] account: $ACCOUNT, bucket: $BUCKET"

# Ensure jwks.json exists
if [ ! -f "$PARENT/jwks.json" ]; then
  echo "[publish-oidc] ERROR: jwks.json not found. Run tools/keygen.sh first." >&2; exit 1
fi

# 1. Create the bucket (us-east-1 needs no LocationConstraint)
if ! aws s3api head-bucket --bucket "$BUCKET" ${PROFILE:+--profile "$PROFILE"} 2>/dev/null; then
  echo "[publish-oidc] creating bucket $BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" ${PROFILE:+--profile "$PROFILE"} --region "$REGION"
fi

# 2. Disable block-public-access (needed for the Gateway to fetch the discovery doc + JWKS)
aws s3api put-public-access-block --bucket "$BUCKET" ${PROFILE:+--profile "$PROFILE"} \
  --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# 3. Set a bucket policy allowing public GetObject (read-only)
aws s3api put-bucket-policy --bucket "$BUCKET" ${PROFILE:+--profile "$PROFILE"} --policy "$(cat <<POLICY
{
  "Version":"2012-10-17",
  "Statement":[{
    "Sid":"PublicReadOIDC",
    "Effect":"Allow",
    "Principal":"*",
    "Action":"s3:GetObject",
    "Resource":"arn:aws:s3:::${BUCKET}/*"
  }]
}
POLICY
)"

# 4. Write the minimal OIDC discovery document
cat > /tmp/openid-configuration <<EOF
{
  "issuer": "${ISSUER_BASE}",
  "jwks_uri": "${ISSUER_BASE}/jwks.json",
  "response_types_supported": ["token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"],
  "token_endpoint_auth_methods_supported": ["private_key_jwt"]
}
EOF
aws s3 cp /tmp/openid-configuration "s3://${BUCKET}/.well-known/openid-configuration" \
  --content-type "application/json" ${PROFILE:+--profile "$PROFILE"} --region "$REGION"

# 5. Upload the JWKS
aws s3 cp "$PARENT/jwks.json" "s3://${BUCKET}/jwks.json" \
  --content-type "application/json" ${PROFILE:+--profile "$PROFILE"} --region "$REGION"

DISCOVERY_URL="${ISSUER_BASE}/.well-known/openid-configuration"
echo
echo "============================================================"
echo "  OIDC discovery published."
echo "    Issuer:        $ISSUER_BASE"
echo "    Discovery URL: $DISCOVERY_URL"
echo "    JWKS URL:      ${ISSUER_BASE}/jwks.json"
echo
echo "  Use this discovery URL for:"
echo "    agentcore add gateway --discovery-url $DISCOVERY_URL"
echo "  And this issuer as --iss when minting JWTs:"
echo "    python3 tools/mint-jwt.py --iss $ISSUER_BASE ..."
echo "============================================================"
