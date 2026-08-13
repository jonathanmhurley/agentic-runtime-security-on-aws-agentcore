# gateway-kb-target

A thin Lambda that wraps `bedrock:Retrieve` on the Meridian Knowledge Base,
registered as an **AgentCore Gateway target**. This is the Gateway-native version
of the Stage 2 broker's "scoped credential" concept — the Gateway's IAM role
holds `bedrock:Retrieve` and brokers access to the KB on the caller's behalf.

## Deploy
```bash
bash deploy.sh
```

## How it works in the Gateway flow
1. Caller presents a JWT to the Gateway (inbound CUSTOM_JWT auth validates it)
2. Gateway routes the `retrieve_from_kb` tool call to this Lambda target
3. Gateway uses its own IAM role (GATEWAY_IAM_ROLE) to invoke the Lambda
4. The Lambda calls bedrock:Retrieve and returns passages
5. Gateway returns the result to the caller

The caller never holds bedrock:Retrieve — the Gateway brokers it. Same principle
as Vault vending a scoped credential, implemented with the native Gateway primitive.
