# Agentic Runtime Security on AWS — AgentCore Edition

**Target-architecture design doc**

Status: proven (UC1-3 validated Aug 2026) · Author: Jonathan Hurley · Date: 2026-08-07 (last updated 2026-08-29)

---

## 1. Purpose

Pivot the existing **Agentic Runtime Security on AWS** workshop from the IBM Verify Identity Access (IVIA) + HashiCorp Vault + Strands-on-EKS reference architecture to an **Amazon Bedrock AgentCore** edition. The agents move off self-managed EKS onto AgentCore Runtime; AgentCore Identity replaces IVIA/OpenLDAP as the token issuer; Vault stays as the secrets/authorization/audit backbone. This is delivered as an **entirely new repository** to avoid collisions with the EKS version and its open findings.

Guiding principles for the pivot:

- **Mirror the existing repo structure** for consistency and reviewer familiarity; deviate only where AgentCore forces it.
- **Expose the technologies without overburdening attendees.** Prefer the shortest repeatable path that fits an instruction set. Keep total runtime in the ~2–3 hr band of the current workshop.
- **Keep the core labs on durable surfaces**, and clearly mark the one beta dependency (Vault Agent Registry).

---

## 2. Confirmed decisions

| # | Decision | Rationale |
| --- | --- | --- |
| 1 | **Agents run on Bedrock AgentCore Runtime** (managed, serverless). No EKS. | Removes the self-managed cluster, ServiceAccounts, NetworkPolicy, node groups. |
| 2 | **AgentCore Identity** facilitates the OBO token exchange; the workshop’s JWT issuer is a self-hosted mock OAuth server with GitHub-hosted JWKS trusted by both the Runtime authorizer and Vault. | Replaces Vault Kubernetes auth + IVIA as issuer. |
| 3 | **AgentCore Secure Token Vault + native OBO** carries user identity on-behalf-of. | Replaces IVIA/CIBA out-of-band consent + token storage. Managed by AgentCore. |
| 4 | **Vault: self-hosted Vault Enterprise on AWS**, license provided by Oscar. | Hard constraint: run on AWS, not HashiCorp Cloud. Enterprise required for the Agent Registry. |
| 5 | **Agent Registry (beta) stays in the core labs.** | Not used in the proven flow. The GA JWT auth method with `bound_subject` provides equivalent allowlist functionality. Enterprise license kept for future exploration. |
| 6 | **OBO target = Vault as the OBO/JWT resource server** (`JWT_AUTHORIZATION_GRANT`). | Shortest repeatable path; one IdP, one downstream. Matches diagram steps 2–5. |
| 7 | **Agent framework = Strands.** | Matches the current workshop; AgentCore Runtime is framework-agnostic so this is a low-risk default. |
| 8 | **New repo, mirroring existing layout.** | No collisions; reviewers familiar with the EKS repo can navigate this one. |
| 9 | **Version pinning is a first-class requirement** (see §7). | Agent Registry is beta; the OBO API surface is moving. Pin to avoid silent breakage. |

---

## 3. Architecture: what stays, what changes, what drops

### 3.1 Drops entirely (EKS + IVIA plane)

Grounded in the current repo (`/Users/hurleyjm/Developer/agentic-runtime-security-on-aws`):

| Current component | Path | Why it drops |
| --- | --- | --- |
| EKS cluster + managed node group | `infrastructure/modules/eks/` | Agents move to AgentCore Runtime. |
| VPC (agent-hosting purpose) | `infrastructure/modules/vpc/` | Reduced/optional — only needed if Vault EC2 lives in a VPC (it will). Kept but slimmed. |
| IVIA / Verify Access | `infrastructure/modules/verify_access/` | Replaced by AgentCore Identity + external OIDC IdP. |
| OpenLDAP + `ldap.key` | `infrastructure/modules/verify_access/base_layer/openldap-keys/` | Identity source replaced; static-key finding disappears. |
| IVIA licensing module + cert | `instruqt/track/03-ivia-licensing/`, `ISAM-Trial-HashiCorp.cer` | No IVIA. |
| EKS add-ons (cert-manager, external-dns, LE issuer) | `infrastructure/modules/addons/` | No cluster → no ALB Ingress TLS machinery. |
| Cross-node LDAPS SG rule | `infrastructure/main.tf` | No OpenLDAP pods. |
| Vault Kubernetes auth config | `infrastructure/modules/vault_config/` (k8s bits) | Replaced by JWT/OIDC auth against AgentCore JWKS. |
| Container images for agent *pods* (5) + K8s manifests | `applications/**/Dockerfile` | The EKS pod/manifest machinery drops. A container image is still built — the AgentCore starter toolkit generates the Dockerfile, builds via CodeBuild, and pushes to ECR — but you no longer hand-write or deploy pods. |

### 3.2 Stays (largely unchanged — the Vault backbone)

| Component | Path | Note |
| --- | --- | --- |
| Vault server (self-hosted Enterprise) | `infrastructure/modules/vault_server/` | Was already a module; retarget from EKS-hosted to EC2/Fargate self-hosted Enterprise. |
| Vault config: JWT auth, secrets engines, policies | `infrastructure/modules/vault_config/` | JWT auth method now points at AgentCore JWKS. Dynamic secrets, PKI, KV unchanged. |
| Vault IAM (Vault→Bedrock STS assume, KMS unseal) | `infrastructure/modules/vault_iam/` | Unchanged in shape. |
| Agent Registry | Vault Enterprise native (Phase 9) | Kept in core labs. Beta — pinned (see §7). |
| Audit (CMK, log groups, Athena) | `infrastructure/modules/audit/` | **Proven as Vault file audit device** (`/var/log/vault-audit.log`). No Athena or CMK needed. Single Vault audit stream (see §3.4). |
| RDS PostgreSQL + pgaudit | `infrastructure/modules/rds/` | **FUTURE STATE / not built.** Workshop uses Bedrock KB as the protected data resource. |
| Bedrock KB | `applications/stage1-kb/` (managed KB) | UC1 read target. **Changed to a fully-managed Bedrock KB** (managed embeddings) — replaces the EKS repo's self-managed AOSS + vector index. 3 API calls vs. a Terraform module. See §3.5. |
| Workshop content scaffold | `workshop/content/**` | Section skeleton reused; narrative rewritten per §5. |
| Deploy orchestration pattern | `infrastructure/scripts/deploy-workshop.sh` | **Aspirational.** Proven path uses manual scripts: `deploy-vault-dev.sh`, per-app `deploy.sh`, and `agentcore deploy`. See RUNBOOK.md. |

### 3.3 Changes (new AgentCore plane)

| New component | Replaces | Detail |
| --- | --- | --- |
| AgentCore Runtime (Strands agents) | EKS agent pods | Managed serverless. Agent code packaged per AgentCore via the starter toolkit (auto-generated Dockerfile → CodeBuild → ECR image → CreateAgentRuntime with an execution role). ECR image stays; the EKS pod/manifest layer drops. |
| AgentCore Identity | IVIA as issuer + Vault k8s auth | Workload identity (ARN) per agent; issues user-context JWT; exposes JWKS endpoint Vault trusts. |
| AgentCore Secure Token Vault | IVIA/CIBA consent + token store | Holds user-delegated OAuth tokens (OBO). |
| OAuth2 credential provider (OBO config) | CIBA out-of-band flow | One `create-oauth2-credential-provider` call with `onBehalfOfTokenExchangeConfig`. |
| External OIDC IdP (mock OAuth server) | OpenLDAP + IVIA user store | Self-hosted mock OAuth Lambda issuing user-delegated JWTs (RFC 8693 actor claim). Pluggable: swap for Cognito / Okta / Entra in production. |

### 3.4 Audit simplification

The current workshop's "money shot" is a three-plane Athena JOIN (IVIA decision log + Vault audit + pgaudit) correlated across trust planes. In the AgentCore edition the JWT carries **resolved user identity end-to-end**, so a **single hash-chained Vault audit log** answers "which user, which agent, what authorization, when." This is a genuine simplification, and it becomes a teaching point in its own right: the correlation key is intrinsic to the token, not reconstructed after the fact.

Retain a light pgaudit reference on the RDS side so attendees can still see the data-plane record line up with the Vault lease, but the heavy 3-plane Athena correlation module is retired.

---

### 3.5 Design choice: managed Bedrock Knowledge Base

The UC1 read target is an **Amazon Bedrock managed Knowledge Base** (`type: MANAGED`,
managed embeddings), not the self-managed AOSS + explicit-embeddings stack the EKS
repo used (`bedrock_kb_aoss` + `bedrock_kb_index`). This is a deliberate simplification:

| Self-managed KB (EKS repo) | Managed KB (AgentCore edition) |
| --- | --- |
| OpenSearch Serverless collection + vector index | Fully-managed vector store (opaque) |
| Embedding model wired explicitly (Nova 2 MM), dimensions set | Managed embeddings, zero config |
| Chunking/parsing config | Managed defaults |
| Multiple IAM + AOSS data-access policies | One KB service role |
| A module's worth of Terraform | 3 API calls (create KB → S3 data source → ingest) |

Rationale: the workshop teaches agent runtime **security**, not RAG internals. The KB
is a supporting actor; the managed type lets us stand up a retrieval target in minutes
and keep focus on identity + least-privilege. Trade-off (accepted): less control over
retrieval internals. Validated Stage 1 KB: `stage1-meridian-kb` (fictional corpus, so
answers are unmistakably KB-grounded).


---

## 4. The OBO / JWT flow (PROVEN — Aug 24 2026)

> **Status:** the full OBO chain is **PROVEN end-to-end** (Aug 24 2026) on account
> 036325003285 in us-east-1. The agent receives an inbound user JWT, performs the OBO
> exchange via AgentCore Identity, presents the resulting token to Vault, and Vault
> vends per-user scoped STS credentials. Both positive (Alice gets access) and negative
> (Bob denied) tests pass. See `docs/RUNBOOK.md` UC2 section for exact commands.
> OBO applies from **UC2 onward**; **UC1 has no user context** and uses the agent's own
> workload identity.

### The two distinct tokens (do not conflate)

There are **two** tokens, issued by two different issuers, validated against two different
JWKS endpoints. Conflating them is the most common way to mis-wire Vault:

1. **AgentCore user-context JWT** — issued by **AgentCore Identity**, validated against
   **AgentCore's** JWKS. In this workshop, we use a self-hosted keypair (GitHub-hosted
   JWKS) trusted by both the Runtime's JWT authorizer and Vault's `auth/jwt/` method.
   It carries the user identity into Vault.
2. **OBO downstream access token** — issued by the **external IdP's** token endpoint via
   the AgentCore OAuth *credential provider*. In this workshop, the mock OAuth server
   issues this token. It carries `sub: <username>` + `act: {sub: uc1-agent}`.

For the workshop's Vault path, **Vault validates the OBO token (#2)** via `auth/jwt/login`.
The token carries the user's identity (`sub: alice@example.com`) and Vault applies
per-user policies based on `bound_subject` in the JWT role configuration.

### Setup (once, in bootstrap)

```bash
aws bedrock-agentcore-control create-oauth2-credential-provider \
  --profile agenticvault \
  --cli-input-json '{
    "name": "workshop-obo-vault",
    "credentialProviderVendor": "CustomOauth2",
    "oauth2ProviderConfigInput": {
      "customOauth2ProviderConfig": {
        "oauthDiscovery": {
          "authorizationServerMetadata": {
            "issuer": "<ISSUER>",
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

> **Lesson (Aug 24):** use `authorizationServerMetadata` with explicit `tokenEndpoint`
> and `authorizationEndpoint`, NOT `discoveryUrl`. The discovery-fetch approach failed
> with "Credential Provider with no Authorization Endpoint information" due to AgentCore
> caching stale metadata. Inline metadata avoids this entirely.

### Runtime (in the agent code)

The Runtime delivers the workload access token (WAT) as a request header. The agent
extracts it and passes it to `get_resource_oauth2_token`:

```bash
# In Python (inside the agent):
# 1. WAT is auto-injected by Runtime into the request context:
wat = context.request_headers['workloadaccesstoken']

# 2. Exchange WAT for OBO token:
identity_client = IdentityClient("us-east-1")
obo_response = identity_client.get_resource_oauth2_token(
    resource_credential_provider_name="workshop-obo-vault",
    oauth2_flow="ON_BEHALF_OF_TOKEN_EXCHANGE",
    scopes=["kb:read"],
    workload_identity_token=wat,  # REQUIRED — not auto-injected
)
obo_token = obo_response["accessToken"]
```

> **Lesson (Aug 24):** `IdentityClient.get_resource_oauth2_token()` requires the
> `workload_identity_token` parameter explicitly. The SDK does NOT auto-read it from
> the runtime context. The `@requires_access_token` decorator does handle this
> automatically, but conflicts with Strands' `@tool` decorator (exposes `access_token`
> as a visible tool parameter). Use the manual `IdentityClient` approach for Strands.

### Grant-type choice

- **`JWT_AUTHORIZATION_GRANT`** (RFC 7523) — no actor token to configure; simplest for the
  lab. Recommended.
- **`TOKEN_EXCHANGE`** (RFC 8693) — requires an `actorTokenContent` of `M2M`,
  `AWS_IAM_ID_TOKEN_JWT`, or `NONE` (M2M does a client-credentials grant first and sends
  the result as the actor token; AWS_IAM_ID_TOKEN_JWT needs
  `iam:EnableOutboundWebIdentityFederation`). Advanced callout only.

### How this reaches Vault

Once the agent holds the OBO token, it presents it to Vault via `auth/jwt/login`
(the GA JWT auth method). Vault validates the signature against the workshop JWKS,
checks `bound_subject` against the user's `sub` claim, and issues a Vault token
with the appropriate per-user policy. The agent then calls `aws/sts/bedrock-reader`
with that Vault token to get scoped STS credentials.

> **Design decision (Aug 24):** uses the GA **JWT auth method** (`auth/jwt/`), NOT the
> beta OAuth Resource Server. The OAuth RS entity-alias lookup is broken in Vault 2.0.4
> for pre-created aliases. The JWT auth method provides the same controls (JWKS
> validation, bound_subject = allowlist, scoped policies) and is fully GA. See
> `VAULT_HANDOFF.md` §1d.

---

## 5. Workshop narrative (use-case mapping)

The current workshop is built around three progressively-layered use cases. They map cleanly onto the AgentCore edition:

| Use case | Current (EKS/IVIA) | AgentCore edition |
| --- | --- | --- |
| **UC1** — workload identity, JIT creds | Non-personalized read-only Strands agent on EKS; Vault k8s auth; reads Bedrock KB | Strands agent on AgentCore Runtime; agent workload identity (ARN); Vault JWT auth via JWKS; reads Bedrock KB. **No user context yet.** |
| **UC2** — user intent (OAuth) | Authorization Code + PKCE via IVIA; personalized read | Bearer token from mock OAuth server; **AgentCore OBO** carries user identity; Vault authorizes per-user; personalized read from **Bedrock KB** with Vault-vended STS creds. **PROVEN Aug 24 2026.** |
| **UC3** — audit inspection | CIBA mobile-push approval; three-plane Athena audit correlation | OBO-scoped read; **single hash-chained Vault audit** answering user+agent+authz+lease. Complete attribution from a single log stream. **PROVEN Aug 28 2026.** |

Section skeleton (reuse the `workshop/content/NN-section/` numbering):

- `10-introduction` — reframe: the three trust planes, now unified by AgentCore-issued JWT.
- `20-prerequisites` — AWS account + Bedrock AgentCore enabled + Bedrock model access; **Vault Enterprise license** (from Oscar) replaces IVIA licensing.
- `30-deploy-foundation` — Vault Enterprise (self-hosted), OIDC IdP, AgentCore setup, OBO credential provider.
- `50-use-case-1` / `60-use-case-2` / `70-use-case-3` — as mapped above.
- `80-cleanup`, `85-summary`, `90-resources`, `95-credits` — carry over.

---

## 6. Deploy story (self-hosted Vault on AWS)

- **One shared Vault Enterprise instance** owned by the content team, stood up by workshop Terraform. **Not** an HA Raft cluster — a single persistent Vault server on a small EC2 instance (or Fargate task) is enough for a lab and keeps "no self-managed *Kubernetes* cluster" true.
- **License injection:** the Enterprise license (from Oscar) is pulled from a secret the content team controls at deploy time (e.g. Secrets Manager), not brought by each attendee. Design around one license baked into the deploy.
- **Tiering:** reuse the `deploy-workshop.sh --tier <n>` pattern, redefined:- Tier 1: foundation (VPC-lite, RDS, Bedrock KB, IAM, audit, Vault IAM/KMS).
- Tier 2: Vault Enterprise server + Vault config (JWT auth, secrets engines, Agent Registry, policies).
- Tier 3: AgentCore setup (Runtime agents, Identity, OBO credential provider) + OIDC IdP wiring.
- **Idempotency:** every script idempotent and safe to re-run (inherited non-negotiable from the current repo's CLAUDE.md).
- **AWS CLI:** all calls use `--profile agenticvault` (the account Stages 0-2 were proven in).

---

## 7. Versioning & beta dependencies (first-class requirement)

The Agent Registry is **beta** in Vault Enterprise, and the AgentCore OBO API surface is still moving. To prevent silent breakage:

**Pin explicitly**

- Vault Enterprise version pinned as a Terraform variable/constant (e.g. `vault_version = "1.x.y+ent"` — pin to the exact Enterprise build that ships the Agent Registry the labs use). No `latest`, no floating tags.
- AgentCore SDK / `bedrock-agentcore` package version pinned in `requirements.txt`. The OBO calls (`get_resource_oauth2_token` via IdentityClient) are moving surfaces. Note: CLI equivalents exist but the proven agent code uses the Python SDK directly with explicit `workload_identity_token` parameter.

**Call out the beta risk where it lives**

- A "Version compatibility" callout in this doc and in the lab section that introduces the Agent Registry: the registry is beta, its API may change, and the workshop is validated only against the pinned version.
- A single **"Tested against"** block (Vault Enterprise version · AgentCore SDK version · region · date), mirroring how the aws-samples OBO repo records its tested baseline. Gives future maintainers a known-good reference.

**Make drift easy to fix, not silent**

- Isolate the registry-specific config in its own Terraform module / lab section so a beta API shift has a one-module blast radius, not a scatter across labs.
- Label each Vault capability GA vs beta in the design: **GA** — JWT auth, dynamic secrets, audit log; **beta** — Agent Registry. A maintainer instantly knows which parts are durable and which need re-validation on a version bump.

**Tested against (known-good baseline)**

| Component | Version | Notes |
| --- | --- | --- |
| AgentCore CLI (`@aws/agentcore`) | `0.26.0` | Node.js CLI; scaffolds + deploys via CDK. |
| `@aws/agentcore-cdk` | `0.1.0-alpha.45` | CLI-managed; alpha — re-validate on CLI bump. |
| `aws-cdk-lib` | `~2.261.0` | CLI-managed (dependency management left enabled). |
| Bedrock model | `us.amazon.nova-pro-v1:0` | Nova Pro via CRIS (bare id rejected for on-demand). |
| Account / region | `<ACCOUNT_ID>` / `us-east-1` | agenticvault account. |
| Stage 0 validated | 2026-08-08 | Deploy + workload identity + invoke on Nova Pro. |
| AgentCore CLI | `0.26.0` (also validated `0.27.1` Aug 24) | Node.js CLI, not the Python starter toolkit. |
| Vault Enterprise | `2.0.4+ent` | Deployed on EC2 (t3.micro, dev mode). License expires 2032-10-22. |

Stage 0 (AgentCore hello-world) is proven against this baseline. Runtime ARN:
`arn:aws:bedrock-agentcore:us-east-1:<ACCOUNT_ID>:runtime/stage0hello_stage0hello-PglC2wCzrZ`.

**Stage 1 (KB read via scoped execution role) is proven** (2026-08-08): the agent
answered a Meridian-corpus-only question ("RapidLane 6-hour SLA") via `bedrock:Retrieve`
on managed KB `QLKOTZM2GC`, using its runtime execution role
(`AgentCore-stage0hello-def-ApplicationAgentStage0hel-sV2ZNvKgNJNS`) as the scoped
credential — the first Vault stand-in. KB data source `272GXVZBBS`, ingestion COMPLETE.

**CLI gotcha (recorded):** this AgentCore CLI (`0.26.0`) does NOT inject
`agentcore.json` `runtimes[].environmentVariables` onto the runtime — `get-agent-runtime`
returned `environmentVariables: null`. Runtime config must be set in code (we use a
`_DEFAULT_KB_ID` fallback) or via the correct CLI env mechanism (TBD), not agentcore.json.

---

## 8. Open items / to track

1. **License logistics with Oscar** — confirm the Enterprise tier (must expose the Agent Registry), the license term (workshop delivery window + re-runs), and delivery mechanism (baked into deploy via a content-team-owned secret). Design assumes one license the content team owns, injected at deploy time.
2. **Beta version pinning** — pin Vault Enterprise + AgentCore SDK versions and add the "Tested against" block before first delivery (see §7).
3. ~~**OIDC IdP choice**~~ — RESOLVED (Aug 24): self-hosted mock OAuth server (`applications/oauth-mock-server/`). Issues user-delegated JWTs with RFC 8693 actor claim. No Cognito needed.
4. ~~**Vault reachability**~~ — RESOLVED (Aug 28): AgentCore Runtime (PUBLIC network mode) reaches Vault via public IP. Requires VPC BPA exclusion + SG port 8200 open.
5. ~~**New repo name + location**~~ — RESOLVED: `github.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore` (public).

---

## 9. Superseded assumptions (for the record)

- ~~HCP Vault Dedicated~~ — rejected: runs in HashiCorp Cloud; hard constraint is AWS-only. **Self-hosted Vault Enterprise on AWS** instead.
- ~~Drop the Agent Registry to avoid Enterprise/beta~~ — rejected: registry kept in core; Oscar provides the license.
- ~~OBO is two hand-wired transformations~~ — corrected: AgentCore performs the OBO exchange natively (one config + two calls).

