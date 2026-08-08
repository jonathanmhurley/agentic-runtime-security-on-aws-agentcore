# Module: agentcore_obo

**NEW.** The OAuth2 credential provider configured for on-behalf-of token exchange (`onBehalfOfTokenExchangeConfig`, `grantType = JWT_AUTHORIZATION_GRANT`). One `create-oauth2-credential-provider` call. AgentCore performs the OBO exchange natively; the agent makes two runtime calls (`get-workload-access-token-for-jwt`, then `get-resource-oauth2-token`). Replaces the IVIA/CIBA out-of-band consent flow.

**Status:** new (replaces CIBA).
