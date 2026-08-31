---
title: 'Register OBO credential provider'
weight: 62
---

## What is a credential provider?

AgentCore Identity manages OAuth2 integrations through **credential providers**. You
register an external token endpoint once. Then any agent on the runtime can call
`GetResourceOauth2Token` to exchange its workload access token for a user-scoped
token from that endpoint.

## Create the credential provider

> **Variables required:** `$MOCK_SERVER_URL` must be set from the
> [Deploy the foundation](../../30-deploy-foundation/) or
> [Deploy the mock server](../61-deploy-mock-server/) steps.
> `$CLIENT_SECRET` must also be set — this is the same value you chose in Step 3 of the foundation.
> [Deploy the mock server](../61-deploy-mock-server/) steps.

```bash
aws bedrock-agentcore-control create-oauth2-credential-provider \
  --region us-east-1 \
  --cli-input-json "{
  \"name\": \"workshop-obo-vault\",
  \"credentialProviderVendor\": \"CustomOauth2\",
  \"oauth2ProviderConfigInput\": {
    \"customOauth2ProviderConfig\": {
      \"oauthDiscovery\": {
        \"authorizationServerMetadata\": {
          \"issuer\": \"${MOCK_SERVER_URL}\",
          \"authorizationEndpoint\": \"${MOCK_SERVER_URL}/token\",
          \"tokenEndpoint\": \"${MOCK_SERVER_URL}/token\"
        }
      },
      \"clientId\": \"workshop-obo-client\",
      \"clientSecret\": \"${CLIENT_SECRET}\",
      \"clientAuthenticationMethod\": \"CLIENT_SECRET_BASIC\",
      \"onBehalfOfTokenExchangeConfig\": { \"grantType\": \"JWT_AUTHORIZATION_GRANT\" }
    }
  }
}"
```

Key decisions:

- **`authorizationServerMetadata`** (not `discoveryUrl`): provides the token endpoint
  inline, avoiding discovery-fetch caching issues. The `issuer` field must match the
  `iss` claim in the JWTs your mock server issues.
- **`JWT_AUTHORIZATION_GRANT`**: the OBO flow. AgentCore presents the workload access
  token as a JWT assertion; the token server returns a new token scoped to the user.
- **`CLIENT_SECRET_BASIC`**: client ID and secret go in the Authorization header as
  HTTP Basic Auth, not in the POST body.
- **`clientSecret`**: can be any string you choose — it just needs to match what the
  mock server expects (the value you set in `$CLIENT_SECRET` during foundation deploy).

Note the `clientSecretArn` in the response — you need this ARN for the IAM policy below.

## Grant the execution role permissions

Discover the execution role name and secret ARN, then attach the required policies:

```bash
# Discover the execution role (created by CDK during agentcore deploy)
EXECUTION_ROLE_NAME=$(aws iam list-roles \
  --query "Roles[?starts_with(RoleName,'AgentCore-stage0hello') && contains(RoleName,'Application')].RoleName | [0]" \
  --output text)
echo "Execution role: $EXECUTION_ROLE_NAME"

# Discover the secret ARN from the credential provider
SECRET_ARN=$(aws bedrock-agentcore-control get-oauth2-credential-provider \
  --name workshop-obo-vault --region us-east-1 \
  --query 'clientSecretArn.secretArn' --output text)
echo "Secret ARN: $SECRET_ARN"

# OBO Identity permissions
aws iam put-role-policy \
  --role-name "$EXECUTION_ROLE_NAME" \
  --policy-name obo-identity \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "bedrock-agentcore:GetResourceOauth2Token",
        "bedrock-agentcore:GetWorkloadAccessToken",
        "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
        "bedrock-agentcore:GetWorkloadAccessTokenForUserId"
      ],
      "Resource": "*"
    }]
  }'

# Secrets Manager access for the managed client secret
aws iam put-role-policy \
  --role-name "$EXECUTION_ROLE_NAME" \
  --policy-name obo-secrets \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"secretsmanager:GetSecretValue\",
      \"Resource\": \"${SECRET_ARN}\"
    }]
  }"
```

## Verify

```bash
aws bedrock-agentcore-control get-oauth2-credential-provider \
  --name workshop-obo-vault \
  --region us-east-1
```

Confirm `workshop-obo-vault` appears with status `READY`.
