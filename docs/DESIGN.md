# Agentic Runtime Security on AWS — AgentCore Edition

**Target-architecture design doc**

Status: draft for review · Author: design pass with Jonathan Hurley · Date: 2026-08-07

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
| 2 | **AgentCore Identity** is the token issuer + JWKS endpoint Vault trusts. | Replaces Vault Kubernetes auth + IVIA as issuer. |
| 3 | **AgentCore Secure Token Vault + native OBO** carries user identity on-behalf-of. | Replaces IVIA/CIBA out-of-band consent + token storage. Managed by AgentCore. |
| 4 | **Vault: self-hosted Vault Enterprise on AWS**, license provided by Oscar. | Hard constraint: run on AWS, not HashiCorp Cloud. Enterprise required for the Agent Registry. |
| 5 | **Agent Registry (beta) stays in the core labs.** | It is already central to the current UC2/UC3 flow (Vault 2.0.3-ent). This is the reason the Enterprise license matters. |
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
| Audit (CMK, log groups, Athena) | `infrastructure/modules/audit/` | Collapses from 3-plane to single Vault audit stream (see §3.4). |
| RDS PostgreSQL + pgaudit | `infrastructure/modules/rds/` | Still the protected data resource for the DB dynamic-secrets demo. |
| Bedrock KB | `applications/stage1-kb/` (managed KB) | UC1 read target. **Changed to a fully-managed Bedrock KB** (managed embeddings) — replaces the EKS repo's self-managed AOSS + vector index. 3 API calls vs. a Terraform module. See §3.5. |
| Workshop content scaffold | `workshop/content/**` | Section skeleton reused; narrative rewritten per §5. |
| Deploy orchestration pattern | `infrastructure/scripts/deploy-workshop.sh` | Tiering pattern reused; tiers redefined (see §6). |

### 3.3 Changes (new AgentCore plane)

| New component | Replaces | Detail |
| --- | --- | --- |
| AgentCore Runtime (Strands agents) | EKS agent pods | Managed serverless. Agent code packaged per AgentCore via the starter toolkit (auto-generated Dockerfile → CodeBuild → ECR image → CreateAgentRuntime with an execution role). ECR image stays; the EKS pod/manifest layer drops. |
| AgentCore Identity | IVIA as issuer + Vault k8s auth | Workload identity (ARN) per agent; issues user-context JWT; exposes JWKS endpoint Vault trusts. |
| AgentCore Secure Token Vault | IVIA/CIBA consent + token store | Holds user-delegated OAuth tokens (OBO). |
| OAuth2 credential provider (OBO config) | CIBA out-of-band flow | One `create-oauth2-credential-provider` call with `onBehalfOfTokenExchangeConfig`. |
| External OIDC IdP (Cognito default) | OpenLDAP + IVIA user store | Pluggable: Cognito / Okta / Entra / IBM Verify. Cognito is the leanest for a vended-account workshop. |

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

## 4. The OBO / JWT flow (grounded)

Confirmed against the [AWS OBO docs](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/on-behalf-of-token-exchange.html) and the [aws-samples OBO reference](https://github.com/aws-samples/sample-bedrock-agentcore-identity-obo-token-exchange) (`04_agent_obo_example.py`, Strands, tested us-east-1, MIT-0).

AgentCore performs the OBO exchange natively — the lab does **not** hand-roll token brokering. The whole flow reduces to **one setup config + two runtime calls**.

**Setup (once, in bootstrap):**

```bash
aws bedrock-agentcore-control create-oauth2-credential-provider \
  --profile agentic \
  --cli-input-json '{
    "name": "workshop-obo-vault",
    "credentialProviderVendor": "CustomOauth2",
    "oauth2ProviderConfigInput": {
      "customOauth2ProviderConfig": {
        "oauthDiscovery": { "discoveryUrl": "https://<idp>/.well-known/openid-configuration" },
        "clientId": "<client-id>",
        "clientSecret": "<client-secret>",
        "clientAuthenticationMethod": "CLIENT_SECRET_BASIC",
        "onBehalfOfTokenExchangeConfig": { "grantType": "JWT_AUTHORIZATION_GRANT" }
      }
    }
  }'

```

**Runtime (in the agent, two calls):**

```bash
# 1. exchange inbound user token → workload access token
aws bedrock-agentcore get-workload-access-token-for-jwt --profile agentic \
  --workload-name workshop-workload --user-token "<inbound-jwt>"

# 2. get the OBO-scoped downstream token
aws bedrock-agentcore get-resource-oauth2-token --profile agentic \
  --resource-credential-provider-name workshop-obo-vault \
  --oauth2-flow ON_BEHALF_OF_TOKEN_EXCHANGE --scopes "<scope>" \
  --workload-identity-token "<workload-access-token>"

```

Vault then validates the presented JWT via the AgentCore JWKS endpoint (JWT auth method), checks the Agent Registry, reads the `authorization_details` claim, and vends short-lived dynamic secrets tied to the JWT lease.

Grant-type choice: `JWT_AUTHORIZATION_GRANT` (RFC 7523) — no actor token to configure, simplest for the lab. `TOKEN_EXCHANGE` (RFC 8693) with an M2M actor token is the alternative, documented as an advanced callout only.

---

## 5. Workshop narrative (use-case mapping)

The current workshop is built around three progressively-layered use cases. They map cleanly onto the AgentCore edition:

| Use case | Current (EKS/IVIA) | AgentCore edition |
| --- | --- | --- |
| **UC1** — workload identity, JIT creds | Non-personalized read-only Strands agent on EKS; Vault k8s auth; reads Bedrock KB | Strands agent on AgentCore Runtime; agent workload identity (ARN); Vault JWT auth via JWKS; reads Bedrock KB. **No user context yet.** |
| **UC2** — user intent (OAuth) | Authorization Code + PKCE via IVIA; personalized read | OIDC login (Cognist/Okta/etc.) + PKCE; **AgentCore OBO** carries user identity; Vault authorizes per-user; personalized read from RDS. |
| **UC3** — privileged write + audit | CIBA mobile-push approval; three-plane Athena audit correlation | OBO-scoped privileged write; **single hash-chained Vault audit** answering user+agent+authz+lease. CIBA replaced by OBO consent. |

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
- **AWS CLI:** all calls use `--profile agentic`.

---

## 7. Versioning & beta dependencies (first-class requirement)

The Agent Registry is **beta** in Vault Enterprise, and the AgentCore OBO API surface is still moving. To prevent silent breakage:

**Pin explicitly**

- Vault Enterprise version pinned as a Terraform variable/constant (e.g. `vault_version = "1.x.y+ent"` — pin to the exact Enterprise build that ships the Agent Registry the labs use). No `latest`, no floating tags.
- AgentCore SDK / `bedrock-agentcore` package version pinned in `requirements.txt`. The OBO calls (`get-workload-access-token-for-jwt`, `get-resource-oauth2-token`) and the Agent Registry are both moving surfaces.

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
| Vault Enterprise | _TBD_ | Pin the exact `+ent` build once Oscar provides the license. |

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
3. **OIDC IdP choice** — Cognito is the leanest default for a vended-account audience; confirm before building UC2.
4. **Vault reachability** — single Vault EC2/Fargate in the workshop VPC; confirm AgentCore Runtime → Vault network path (public endpoint vs VPC) during deploy design.
5. **New repo name + location** — create the new repo (mirroring layout) before code work begins.

---

## 9. Superseded assumptions (for the record)

- ~~HCP Vault Dedicated~~ — rejected: runs in HashiCorp Cloud; hard constraint is AWS-only. **Self-hosted Vault Enterprise on AWS** instead.
- ~~Drop the Agent Registry to avoid Enterprise/beta~~ — rejected: registry kept in core; Oscar provides the license.
- ~~OBO is two hand-wired transformations~~ — corrected: AgentCore performs the OBO exchange natively (one config + two calls).

