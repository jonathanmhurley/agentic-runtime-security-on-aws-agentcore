# Project Instructions — agentic-runtime-security-on-aws-agentcore

This is the **AgentCore edition** — a new-repo pivot of the EKS/IVIA workshop. Structure mirrors the original; deviate only where AgentCore forces it.

## Scope constraints (final, do not relitigate)

- **No EKS.** Agents run on Amazon Bedrock AgentCore Runtime (managed, serverless). No cluster, node group, ServiceAccounts, NetworkPolicy, Karpenter, or ArgoCD.
- **No IVIA / IBM Verify Identity Access, no OpenLDAP.** Identity is an external OIDC IdP + AgentCore Identity as token issuer. No IBM licensing artifacts anywhere.
- **No Cognito required.** The workshop uses a self-hosted mock OAuth server (`applications/oauth-mock-server/`) issuing user-delegated JWTs. Cognito/Okta/Entra are plug-in alternatives for production but not needed in the lab.
- **Vault = self-hosted Vault Enterprise on AWS** (NOT HCP Vault Dedicated — hard constraint: run on AWS, not HashiCorp Cloud). Enterprise license provided by Oscar/content team, injected at deploy from a content-team-owned secret. Single persistent Vault server (EC2/Fargate), NOT an HA Raft cluster.
- **Agent Registry (beta) stays in the core labs** — it is the reason the Enterprise license matters. Pin the Vault Enterprise version; isolate registry config in its own module.
- **OBO = Vault as the OBO/JWT resource server**, `JWT_AUTHORIZATION_GRANT` (RFC 7523). AgentCore performs the exchange natively (one credential-provider config + two runtime calls). Do NOT hand-roll token brokering.
- **Credential provider: use `authorizationServerMetadata` (NOT `discoveryUrl`)** when registering the OBO provider. The discovery-fetch approach fails with stale cached metadata. Inline `tokenEndpoint` + `authorizationEndpoint` directly.
- **Execution role needs `secretsmanager:GetSecretValue`** on the AgentCore-managed client secret ARN. Without this, `GetResourceOauth2Token` returns AccessDeniedException.
- **WAT access pattern:** `context.request_headers['workloadaccesstoken']` in the entrypoint. Pass explicitly to `IdentityClient.get_resource_oauth2_token(workload_identity_token=...)`. The SDK does NOT auto-inject it.
- **JWT authorizer must be in `agentcore.json`**, not just applied via `update-agent-runtime` CLI. CDK deploy (`agentcore deploy`) overwrites the runtime config from `agentcore.json` on every deploy.
- **Gateway `allowedClients` is required** (CDK 0.1.0-alpha.50+). The JWT must include a `client_id` claim matching an entry in the Gateway's `allowedClients` array. Without this, the Gateway returns `-32002 insufficient_scope`. Default: `"allowedClients": ["workshop-client"]` in `agentcore.json`.
- **Lambda Function URLs (AuthType: NONE) blocked** on Workshop Studio vended accounts AND internal Amazon accounts. Always use API Gateway HTTP API as the public endpoint for the mock OAuth server.
- **Vault AWS STS roles require `ttl >= 15m`** (AWS STS minimum DurationSeconds is 900). `vault write aws/sts/<role> ttl=5m` fails with an InvalidParameter error.
- **Bedrock LLM = Amazon Nova Pro** via CRIS profile `us.amazon.nova-pro-v1:0` (NOT bare `amazon.nova-pro-v1:0`). **Embedding = Amazon Nova 2 Multimodal Embeddings** (`amazon.nova-2-multimodal-embeddings-v1:0`, us-east-1 only). KB components in us-east-1 via `provider.aws.kb`; everything else in `var.region`.
- **Canonical region contract**: no `us-west-2`/`us-east-1` string literals outside the tfvars/deploy config. All modules interpolate `var.region` / `var.kb_region`.
- **AWS CLI: always `--profile agenticvault`.**

## Version pinning (first-class requirement)

- Pin Vault Enterprise version (exact `+ent` build shipping the Agent Registry used by the labs). No `latest`/floating tags.
- Pin `bedrock-agentcore` SDK version in every `applications/*/requirements.txt`.
- Maintain a single **"Tested against"** block (Vault Enterprise version · AgentCore SDK · region · date) in `docs/DESIGN.md`.
- Label Vault capabilities GA vs beta: GA = JWT auth, dynamic secrets, audit; beta = Agent Registry.
- **Tested CLI versions:** AgentCore CLI 0.27.1 (`@aws/agentcore`), Vault CLI 2.0.4+ent.

## Code conventions

- **Every script MUST be idempotent and safe to re-run end-to-end — no exceptions.** Applies especially to `deploy-workshop.sh`.
- Atomic commits per logical change; prefer explicit `git add <path>` over `git add -A`.
- Terraform fmt clean; every module carries a README.md as authoritative module documentation.

## Don't

- Don't reintroduce EKS, IVIA, OpenLDAP, Karpenter, or ArgoCD references.
- Don't add HCP Vault Dedicated — Vault runs self-hosted on AWS.
- Don't ask the user to re-confirm the constraints above. They are settled.
- **Don't speculate.** Never add config keys or API values not confirmed in official AWS/HashiCorp docs or verified live. Research first.
- **Never modify files the user didn't ask to change.** Only commit files related to the current task.
