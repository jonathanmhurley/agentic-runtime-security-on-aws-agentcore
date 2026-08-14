#!/usr/bin/env bash
# deploy-vault-dev.sh — Launch a single EC2 instance running Vault Enterprise in dev mode.
#
# This is the fastest path to a running Vault Enterprise with the Agent Registry +
# OAuth resource server enabled. Dev mode = in-memory, no unseal, data lost on stop.
# Replace with a proper Raft/KMS-unseal config for anything persistent.
#
# Prerequisites:
#   - AWS profile with EC2/IAM/SG permissions (agenticvault)
#   - The Vault Enterprise license at infrastructure/modules/vault_server/vault.hclic
#   - A default VPC in us-east-1 (or pass VPC_ID/SUBNET_ID)
#
# Usage:
#   bash deploy-vault-dev.sh
#
# Outputs: VAULT_ADDR, VAULT_TOKEN (dev-mode root token)
set -euo pipefail
PROFILE="${AWS_PROFILE:-agenticvault}"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LICENSE_FILE="$HERE/vault.hclic"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
KEY_NAME="${KEY_NAME:-}"  # optional SSH key pair name
SG_NAME="vault-dev-sg"
INSTANCE_NAME="vault-enterprise-dev"

echo "[vault-dev] account: $ACCOUNT, region: $REGION"

# Validate license file exists
if [ ! -f "$LICENSE_FILE" ]; then
  echo "ERROR: Vault Enterprise license not found at $LICENSE_FILE" >&2
  echo "  Place your .hclic file there (gitignored)." >&2
  exit 1
fi
LICENSE="$(cat "$LICENSE_FILE")"

# 1. Security group — open port 8200 (Vault API) from anywhere (lab only!)
SG_ID="$(aws ec2 describe-security-groups --profile "$PROFILE" --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")"
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  echo "[vault-dev] creating security group $SG_NAME"
  SG_ID="$(aws ec2 create-security-group --profile "$PROFILE" --region "$REGION" \
    --group-name "$SG_NAME" --description "Vault dev-mode (port 8200)" \
    --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress --profile "$PROFILE" --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 8200 --cidr 0.0.0.0/0
  echo "[vault-dev] SG $SG_ID created (port 8200 open)"
else
  echo "[vault-dev] SG $SG_ID already exists"
fi

# 2. Find latest Amazon Linux 2023 AMI
AMI_ID="$(aws ec2 describe-images --profile "$PROFILE" --region "$REGION" \
  --owners amazon --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
  --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" --output text)"
echo "[vault-dev] AMI: $AMI_ID"

# 3. User-data script — installs Vault Enterprise + starts in dev mode with license
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -ex

# Install Vault Enterprise
yum install -y yum-utils
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
yum install -y vault-enterprise

# Write the license
cat > /opt/vault/vault.hclic <<'LIC'
__LICENSE_PLACEHOLDER__
LIC

# Start Vault in dev mode with the Enterprise license
export VAULT_LICENSE_PATH=/opt/vault/vault.hclic
# Dev mode: listen on all interfaces so the agent can reach it
vault server -dev -dev-listen-address="0.0.0.0:8200" -dev-root-token-id="workshop-root-token" &

# Wait for Vault to be ready
sleep 5
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="workshop-root-token"
vault status
USERDATA
)
# Inject the actual license into the user-data
USER_DATA="${USER_DATA//__LICENSE_PLACEHOLDER__/$LICENSE}"

# 4. Launch the instance
echo "[vault-dev] launching $INSTANCE_TYPE instance..."
LAUNCH_ARGS=(
  --profile "$PROFILE" --region "$REGION"
  --image-id "$AMI_ID"
  --instance-type "$INSTANCE_TYPE"
  --security-group-ids "$SG_ID"
  --user-data "$USER_DATA"
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]"
  --metadata-options "HttpTokens=required"
)
if [ -n "$KEY_NAME" ]; then
  LAUNCH_ARGS+=(--key-name "$KEY_NAME")
fi
INSTANCE_ID="$(aws ec2 run-instances "${LAUNCH_ARGS[@]}" \
  --query "Instances[0].InstanceId" --output text)"
echo "[vault-dev] instance: $INSTANCE_ID — waiting for running..."

aws ec2 wait instance-running --profile "$PROFILE" --region "$REGION" --instance-ids "$INSTANCE_ID"

# 5. Get the public IP
PUBLIC_IP="$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)"

VAULT_ADDR="http://$PUBLIC_IP:8200"
echo
echo "============================================================"
echo "  Vault Enterprise (dev mode) deployed."
echo "    Instance:    $INSTANCE_ID"
echo "    Public IP:   $PUBLIC_IP"
echo "    VAULT_ADDR:  $VAULT_ADDR"
echo "    VAULT_TOKEN: workshop-root-token"
echo
echo "  Wait ~60s for user-data to finish installing Vault, then:"
echo "    export VAULT_ADDR=$VAULT_ADDR"
echo "    export VAULT_TOKEN=workshop-root-token"
echo "    vault status"
echo
echo "  NOTE: dev mode = in-memory. Data is lost on instance stop."
echo "  To tear down: aws ec2 terminate-instances --instance-ids $INSTANCE_ID --profile $PROFILE --region $REGION"
echo "============================================================"
