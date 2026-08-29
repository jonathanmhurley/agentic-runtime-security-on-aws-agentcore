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

```bash
aws bedrock-agentcore-control create-oauth2-credential-provider \
  --profile agenticvault --region us-east-1 \
  --cli-input-json '{
  "name": "workshop-obo-vault",
  "credentialProviderVendor": "CustomOauth2",
  "oauth2ProviderConfigInput": {
    "customOauth2ProviderConfig": {
      "oauthDiscovery": {
        "authorizationServerMetadata": {
          "issuer": "https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin",
          "authorizationEndpoint": "<FUNCTION_URL>/token",
          "tokenEndpoint": "<FUNCTION_URL>/token"
        }
      },
      "clientId": "workshop-obo-client",
      "clientSecret": "<CLIENT_SECRET>",
      "clientAuthenticationMethod": "CLIENT_SECRET_BASIC",
      "onBehalfOfTokenExchangeConfig": { "grantType": "JWT_AUTHORIZATION_GRANT" }
    }
  }
}'
```

Key decisions:

- **`authorizationServerMetadata`** (not `discoveryUrl`): provides the token endpoint
  inline, avoiding discovery-fetch caching issues. The `issuer` field must match the
  `iss` claim in the JWTs your mock server issues.
- **`JWT_AUTHORIZATION_GRANT`**: the OBO flow. AgentCore presents the workload access
  token as a JWT assertion; the token server returns a new token scoped to the user.
- **`CLIENT_SECRET_BASIC`**: client ID and secret go in the Authorization header as
  HTTP Basic Auth, not in the POST body.

Note the `clientSecretArn` in the response. AgentCore stores your client secret in
Secrets Manager automatically. You need this ARN for the IAM policy below.

## Grant the execution role permissions

The runtime's execution role needs two additional policies. Add them with `put-role-policy`:

```bash
# OBO Identity permissions
aws iam put-role-policy \
  --role-name <EXECUTION_ROLE_NAME> \
  --profile agenticvault --region us-east-1 \
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
  --role-name <EXECUTION_ROLE_NAME> \
  --profile agenticvault --region us-east-1 \
  --policy-name obo-secrets \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "<SECRET_ARN_FROM_CREDENTIAL_PROVIDER_OUTPUT>"
    }]
  }'
```

Replace `<SECRET_ARN_FROM_CREDENTIAL_PROVIDER_OUTPUT>` with the `clientSecretArn.secretArn`
value from the `create-oauth2-credential-provider` response.

## Verify

```bash
aws bedrock-agentcore-control get-oauth2-credential-provider \
  --name workshop-obo-vault \
  --profile agenticvault --region us-east-1
```

Confirm `workshop-obo-vault` appears with status `READY`.
