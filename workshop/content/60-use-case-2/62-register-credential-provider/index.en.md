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
aws bedrock-agentcore create-resource-oauth2-credential-provider \
  --name workshop-obo-vault \
  --credential-provider-vendor CustomOauth2 \
  --grant-type JWT_AUTHORIZATION_GRANT \
  --client-authentication-method CLIENT_SECRET_BASIC \
  --authorization-server-metadata '{
    "tokenEndpoint": "<FUNCTION_URL>/token",
    "authorizationEndpoint": "<FUNCTION_URL>/token"
  }' \
  --client-id workshop-obo-client \
  --client-secret "<CLIENT_SECRET>" \
  --profile agenticvault --region us-east-1
```

Key decisions:

- **`authorizationServerMetadata`** (not `discoveryUrl`): avoids runtime discovery
  latency and handles endpoints that return metadata at non-standard paths.
- **`JWT_AUTHORIZATION_GRANT`**: the OBO flow. AgentCore presents the workload access
  token as an assertion; the token server returns a new token scoped to the user.
- **`CLIENT_SECRET_BASIC`**: client ID and secret go in the Authorization header as
  HTTP Basic Auth, not in the POST body.

## Grant the execution role permission

The runtime's execution role needs two additional permissions:

```json
{
  "Effect": "Allow",
  "Action": "bedrock-agentcore:GetResourceOauth2Token",
  "Resource": "*"
},
{
  "Effect": "Allow",
  "Action": "secretsmanager:GetSecretValue",
  "Resource": "arn:aws:secretsmanager:us-east-1:036325003285:secret:AgentCoreIdentity*"
}
```

The `secretsmanager` permission is required because AgentCore Identity stores the
client secret as a managed Secrets Manager secret and the execution role must read it
at exchange time.

## Verify

```bash
aws bedrock-agentcore list-resource-oauth2-credential-providers \
  --profile agenticvault --region us-east-1
```

Confirm `workshop-obo-vault` appears with status `ACTIVE`.
