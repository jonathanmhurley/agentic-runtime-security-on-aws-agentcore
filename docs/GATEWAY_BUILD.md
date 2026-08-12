# Gateway-first proof-of-value (Stage 2b)

Demonstrates the Agentic credential-exchange flow **natively inside AgentCore
Runtime + Gateway** — no hand-built broker Lambda, no Vault, no Cognito. Directly
answers Welly's steer: "the immediate proof of value is to demonstrate how it works
inside AgentCore Runtime / Gateway."

This replaces the Stage 2 broker stand-in with the **real AgentCore Gateway
primitive**: inbound JWT auth (OIDC discovery) + outbound scoped credential
(GATEWAY_IAM_ROLE) + downstream target (KB retrieve). Same security flow, native
implementation.

---

## Architecture (what the proof shows)

```
End user / test caller
  │  (Bearer JWT — signed with our local keypair, validated by Gateway)
  ▼
AgentCore Gateway (CUSTOM_JWT inbound auth — trusts our S3-hosted OIDC discovery)
  │  → validates JWT signature via JWKS
  │  → checks allowedAudience / allowedClients
  │  → outbound auth: GATEWAY_IAM_ROLE (scoped to bedrock:Retrieve on one KB)
  ▼
Target: KB Retrieve Lambda (or direct Bedrock call)
  │
  ▼
Answer from the Meridian Knowledge Base
```

This is the **native version of Stage 2's broker flow**: present JWT → validate via
JWKS → authorize → scoped credential → downstream resource. But now the broker is
Gateway and the transport is a native MCP tool call.

---

## Prerequisites

- Stages 0-1 proven (agent on Runtime + managed KB with Meridian corpus)
- `applications/vault-standin/` keypair exists (`keygen.sh` already run, `jwks.json` present)
- AWS profile `agenticvault` working (us-east-1)

---

## Step 1: Publish the OIDC discovery + JWKS to S3

Gateway's `CUSTOM_JWT` authorizer needs a `discoveryUrl` ending in
`/.well-known/openid-configuration` — a bare JWKS URL isn't enough. This script
publishes a minimal static OIDC discovery document + the JWKS to a public S3 bucket.

```bash
cd /Users/hurleyjm/Developer/agentic-runtime-security-on-aws-agentcore/applications/vault-standin
bash tools/publish-oidc.sh
```

Notes the printed values:
- **DISCOVERY_URL** — for `agentcore add gateway --discovery-url ...`
- **ISSUER_BASE** — for `mint-jwt.py --iss ...` (replaces the old gist URL as the issuer)

> **Security note:** the S3 bucket is public-read (Gateway must fetch the discovery doc
> without auth). Only public keys live there — `private.pem` stays local.

---

## Step 2: Add a Gateway to the agent project

From inside the `stage0hello` project:

```bash
cd /Users/hurleyjm/Developer/agentic-runtime-security-on-aws-agentcore/applications/stage0hello

agentcore add gateway \
  --name workshop-gateway \
  --authorizer-type CUSTOM_JWT \
  --discovery-url "<DISCOVERY_URL from step 1>" \
  --allowed-audience vault-standin \
  --runtimes stage0hello
```

This registers a Gateway in `agentcore.json` with:
- Inbound auth: CUSTOM_JWT trusting our S3-hosted OIDC discovery (validates JWT sig + aud)
- Connected to the `stage0hello` runtime

Then deploy:

```bash
agentcore deploy
```

Confirm the Gateway reaches READY:

```bash
agentcore status
```

---

## Step 3: Add a target (KB retrieve)

The Gateway needs a downstream **target** — the thing it calls with its outbound
credentials. Two options (pick one):

**Option A — Lambda target that wraps `bedrock:Retrieve`:**
A small Lambda that takes a query, calls `bedrock:Retrieve` on the Meridian KB, and
returns passages. Gateway calls it with `GATEWAY_IAM_ROLE` outbound auth (the
Gateway's execution role, granted `lambda:InvokeFunction` + `bedrock:Retrieve`).

**Option B — Direct Bedrock target (if Gateway supports it natively):**
If Gateway supports a direct AWS-service target for Bedrock (some CDK constructs
suggest SigV4 to service endpoints), this avoids the Lambda wrapper. Check at build
time.

Either way, the key: the **Gateway's IAM role** (not the agent's execution role) is
what holds `bedrock:Retrieve` — proving that the credential is brokered by Gateway,
not held by the agent directly.

> This is TODO — the target Lambda/config needs to be built and deployed. See below.

---

## Step 4: Mint a JWT and invoke via the Gateway

Mint with the **S3 issuer** (not the old gist URL):

```bash
cd /Users/hurleyjm/Developer/agentic-runtime-security-on-aws-agentcore/applications/vault-standin
JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "<ISSUER_BASE from step 1>" --scopes kb:read --kid stage2-key-1 --ttl 900)"
```

Invoke the agent, passing the JWT so it calls the Gateway tool:

```bash
cd ../stage0hello
agentcore invoke "{\"prompt\": \"Use the gateway to look up the RapidLane SLA\", \"jwt\": \"$JWT\"}"
```

**Proof:** the agent answers the Meridian SLA (6 hours if booked before 11 AM), and the
Gateway logs show JWT validation succeeded and the target was invoked with scoped creds.

---

## What this proves vs. Stage 2

| Aspect | Stage 2 (broker Lambda) | Stage 2b (Gateway) |
|---|---|---|
| JWT validation | Hand-written PyJWKClient | Native Gateway CUSTOM_JWT authorizer |
| Allowlist / audience | Lambda allowlist (`ALLOWED_SUBS`) | Gateway `allowedAudience` / `allowedClients` |
| Scoped credential | Lambda `sts:AssumeRole` | Gateway `GATEWAY_IAM_ROLE` outbound |
| Transport | Agent → `lambda.invoke` | Agent → MCP tool call (native) |
| Infrastructure | We wrote + deployed it | AWS manages it |

Same security flow, native implementation, fewer moving parts.

---

## Open items (to resolve during build)

1. **The Gateway target shape**: does the AgentCore CLI's `agentcore add gateway` also
   add targets, or is that a separate `create_gateway_target` API call? Confirm at build.
2. **How the agent calls Gateway tools**: if the Gateway is registered as an MCP server
   connected to the runtime, tools defined on its targets should appear in the agent's
   tool list automatically (same as the scaffold's `mcp_client`). Confirm.
3. **Epoxy/Palisade**: the public S3 bucket will likely trip the same scanner that flagged
   the Lambda Function URL. Since it only holds public keys + an OIDC discovery doc (no
   secrets), this is a "by design" exemption case. Decide whether to pre-file or wait
   for the ticket.

---

## Relationship to Stage 3 (real Vault)

Gateway and Vault are **parallel** in the final architecture, not nested (see
VAULT_HANDOFF.md). This Gateway proof demonstrates that the native AgentCore credential
flow works. Vault adds the **Agent Registry + RAR + dynamic secrets + audit** governance
layer on top — the agent presents the same JWT directly to Vault (Topology C). Neither
is "behind" the other.
