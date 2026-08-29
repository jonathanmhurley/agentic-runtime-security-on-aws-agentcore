#!/usr/bin/env bash
# Stage 1 — stand up a fully-managed Bedrock Knowledge Base (zero-config embeddings).
# Idempotent-ish: safe to re-run; it will skip creation if the KB already exists by name.
# AWS CLI calls use --profile $AWS_PROFILE if set; otherwise default credentials. Region us-east-1.
#
# Steps (per AWS docs, managed KB = 3 calls + a service role + an S3 upload):
#   1. Create an S3 bucket + upload the corpus/
#   2. Create a KB service role (trust bedrock.amazonaws.com; allow S3 read + KB)
#   3. create-knowledge-base (type MANAGED, embeddingModelType MANAGED)
#   4. create-data-source (S3)
#   5. start-ingestion-job
# Prints the KB_ID at the end — paste it into agentcore/agentcore.json
# (runtimes[0].environmentVariables.BEDROCK_KB_ID) and into the exec-role policy.
set -euo pipefail

PROFILE="${AWS_PROFILE:-}"
REGION=us-east-1
ACCOUNT="$(aws sts get-caller-identity ${PROFILE:+--profile "$PROFILE"} --query Account --output text)"
KB_NAME=stage1-meridian-kb
DS_NAME=stage1-meridian-s3
BUCKET=stage1-meridian-kb-${ACCOUNT}
ROLE_NAME=Stage1BedrockKBRole
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[stage1-kb] identity check (expect ${ACCOUNT})"
aws sts get-caller-identity ${PROFILE:+--profile "$PROFILE"} --query Account --output text

# 1. S3 bucket + corpus upload -------------------------------------------------
if ! aws s3api head-bucket --bucket "$BUCKET" ${PROFILE:+--profile "$PROFILE"} 2>/dev/null; then
  echo "[stage1-kb] creating bucket $BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" ${PROFILE:+--profile "$PROFILE"} --region "$REGION"
fi
echo "[stage1-kb] syncing corpus/"
aws s3 sync "$HERE/corpus" "s3://$BUCKET/corpus/" ${PROFILE:+--profile "$PROFILE"} --region "$REGION"

# 2. KB service role -----------------------------------------------------------
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$ROLE_NAME" ${PROFILE:+--profile "$PROFILE"} >/dev/null 2>&1; then
  echo "[stage1-kb] creating role $ROLE_NAME"
  aws iam create-role --role-name "$ROLE_NAME" ${PROFILE:+--profile "$PROFILE"} \
    --assume-role-policy-document "$TRUST"
fi
echo "[stage1-kb] attaching inline policy (S3 read + bedrock KB)"
aws iam put-role-policy --role-name "$ROLE_NAME" ${PROFILE:+--profile "$PROFILE"} \
  --policy-name stage1-kb-access \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[\
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"]},\
    {\"Effect\":\"Allow\",\"Action\":[\"bedrock:*\"],\"Resource\":\"*\"}]}"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
echo "[stage1-kb] role arn: $ROLE_ARN"
echo "[stage1-kb] (waiting 10s for role propagation)"; sleep 10

# 3. Managed KB ----------------------------------------------------------------
KB_ID="$(aws bedrock-agent list-knowledge-bases ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
  --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId | [0]" --output text)"
if [ "$KB_ID" = "None" ] || [ -z "$KB_ID" ]; then
  echo "[stage1-kb] creating managed KB $KB_NAME"
  KB_ID="$(aws bedrock-agent create-knowledge-base ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
    --name "$KB_NAME" --role-arn "$ROLE_ARN" \
    --knowledge-base-configuration '{"type":"MANAGED","managedKnowledgeBaseConfiguration":{"embeddingModelType":"MANAGED"}}' \
    --query "knowledgeBase.knowledgeBaseId" --output text)"
fi
echo "[stage1-kb] KB_ID=$KB_ID"

# 3b. Wait for the KB to reach ACTIVE before creating the data source.
# Managed KB creation is async; create-data-source fails with ConflictException
# ("not in a valid status") if the KB is still CREATING. Poll up to ~2 min.
echo "[stage1-kb] waiting for KB to reach ACTIVE..."
for i in $(seq 1 24); do
  KB_STATUS="$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" \
    ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --query "knowledgeBase.status" --output text 2>/dev/null || echo UNKNOWN)"
  echo "  [$i] status=$KB_STATUS"
  [ "$KB_STATUS" = "ACTIVE" ] && break
  sleep 5
done

# 4. S3 data source ------------------------------------------------------------
DS_ID="$(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
  --query "dataSourceSummaries[?name=='${DS_NAME}'].dataSourceId | [0]" --output text 2>/dev/null || echo None)"
if [ "$DS_ID" = "None" ] || [ -z "$DS_ID" ]; then
  echo "[stage1-kb] creating S3 data source"
  DS_ID="$(aws bedrock-agent create-data-source ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
    --knowledge-base-id "$KB_ID" --name "$DS_NAME" \
    --data-source-configuration "{\"type\":\"MANAGED_KNOWLEDGE_BASE_CONNECTOR\",\"managedKnowledgeBaseConnectorConfiguration\":{\"connectorParameters\":{\"type\":\"S3\",\"version\":\"1\",\"connectionConfiguration\":{\"bucketName\":\"$BUCKET\",\"bucketOwnerAccountId\":\"$ACCOUNT\"},\"filterConfiguration\":{\"inclusionPrefixes\":[\"corpus/\"]}}}}" \
    --query "dataSource.dataSourceId" --output text)"
fi
echo "[stage1-kb] DS_ID=$DS_ID"

# 4b. Managed KB data source is async (CREATING -> AVAILABLE, ~2-5 min). Wait before ingesting.
echo "[stage1-kb] waiting for data source to reach AVAILABLE..."
for i in $(seq 1 36); do
  DS_STATUS="$(aws bedrock-agent get-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
    ${PROFILE:+--profile "$PROFILE"} --region "$REGION" --query "dataSource.status" --output text 2>/dev/null || echo UNKNOWN)"
  echo "  [$i] ds_status=$DS_STATUS"
  [ "$DS_STATUS" = "AVAILABLE" ] && break
  sleep 5
done

# 5. Ingest --------------------------------------------------------------------
echo "[stage1-kb] starting ingestion job"
aws bedrock-agent start-ingestion-job ${PROFILE:+--profile "$PROFILE"} --region "$REGION" \
  --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --query "ingestionJob.status" --output text

cat <<EOF

============================================================
  Stage 1 KB ready.
    KB_ID = $KB_ID
  Next:
    1. Put KB_ID into agentcore/agentcore.json
       (runtimes[0].environmentVariables.BEDROCK_KB_ID)
    2. Grant the runtime execution role bedrock:Retrieve on:
       arn:aws:bedrock:${REGION}:${ACCOUNT}:knowledge-base/$KB_ID
    3. agentcore deploy && agentcore invoke "..."
  Ingestion runs async (managed KB: ~2-5 min). Check with:
    aws bedrock-agent list-ingestion-jobs --knowledge-base-id $KB_ID --data-source-id $DS_ID ${PROFILE:+--profile $PROFILE} --region $REGION
============================================================
EOF
