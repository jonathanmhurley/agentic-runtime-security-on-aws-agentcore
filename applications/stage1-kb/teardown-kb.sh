#!/usr/bin/env bash
# Stage 1 — tear down the managed KB, data source, bucket, and role. Idempotent.
set -euo pipefail
PROFILE="${AWS_PROFILE:-}"
REGION=us-east-1
ACCOUNT="$(aws sts get-caller-identity ${PROFILE:+--profile "$PROFILE"} --query Account --output text)"
KB_NAME=stage1-meridian-kb
BUCKET=stage1-meridian-kb-${ACCOUNT}
ROLE_NAME=Stage1BedrockKBRole

KB_ID="$(aws bedrock-agent list-knowledge-bases ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
  --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId | [0]" --output text 2>/dev/null || echo None)"
if [ "$KB_ID" != "None" ] && [ -n "$KB_ID" ]; then
  echo "[teardown] deleting KB $KB_ID (removes its data sources)"
  aws bedrock-agent delete-knowledge-base --knowledge-base-id "$KB_ID" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" || true
fi
echo "[teardown] emptying + deleting bucket $BUCKET"
aws s3 rm "s3://$BUCKET" --recursive ${PROFILE:+--profile "$PROFILE"} --region "$REGION" 2>/dev/null || true
aws s3api delete-bucket --bucket "$BUCKET" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" 2>/dev/null || true
echo "[teardown] deleting role $ROLE_NAME"
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name stage1-kb-access ${PROFILE:+--profile "$PROFILE"} 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" ${PROFILE:+--profile "$PROFILE"} 2>/dev/null || true
echo "[teardown] done"
