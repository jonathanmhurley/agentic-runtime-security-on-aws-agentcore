# Stage 3 handoff — what we need from Vault

This is the pickup point for standing up **real HashiCorp Vault Enterprise** to replace
the Stage 2 credential-broker stand-in. Stages 0-2 are proven (see `RUNBOOK.md`); the
broker faithfully mimics what Vault must now do for real.

**The core promise that makes this a drop-in:** the agent asks for credentials through
one stable interface — `get_scoped_credentials(jwt)` (present a JWT, receive short-lived
scoped creds). Stage 2 pointed that at a Lambda; Stage 3 points it at Vault. **The agent
logic does not change — only the endpoint/transport it calls.**

---

## 1. What Vault must provide (the UC1 slice, already specified in Terraform)

Everything Vault needs for UC1 is already written as the target spec in
`infrastructure/modules/vault_config/main.tf`. Stage 3 is: stand up Vault Enterprise,
then `terraform apply` that module against it. The module provisions:

| Vault resource | What it does | Stand-in it replaces (Stage 2) |
|---|---|---|
| `vault_audit` (file -> stdout, JSON) | Single hash-chained audit stream | CloudWatch broker logs |
| `vault_oauth_resource_server_config_profile.agentcore` | Validates the AgentCore JWT **directly via `X-Vault-Token`** against the AgentCore JWKS endpoint — no Vault login round-trip | Lambda JWKS validation |
| `vault_database_secret_backend_role.uc1_readonly` | SELECT-only Postgres creds, TTL 900s | STS AssumeRole into a scoped role |
| `vault_aws_secret_backend_role.bedrock_reader` | `aws/sts/bedrock-reader` scoped Bedrock STS | the vended `bedrock:Retrieve` role |
| `vault_policy.uc1` | `read` on `database/creds/uc1-readonly` + `aws/sts/bedrock-reader` | broker's implicit scope |
| `vault_agent_registration.uc1` | Registers `uc1-agent` as an approved identity — **unregistered agents blocked** (BETA, Enterprise) | broker allowlist (`ALLOWED_SUBS`) |

**Provider pin:** `hashicorp/vault >= 5.10.1, < 6.0.0` — the first release exposing
`vault_oauth_resource_server_config_profile` + `vault_agent_registration`. Do not float.

---

## 1b. Phase A RESOLVED — JWT issuer + claim shape confirmed

The following inputs to `vault_config` are now confirmed. Oscar can configure Vault
against these without further discovery:

| Input | Value | Source |
|---|---|---|
| `agentcore_issuer` | `https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin` | GitHub-hosted static OIDC discovery (same issuer Gateway already trusts) |
| `agentcore_jwks_url` | `https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin/jwks.json` | Committed to the public repo; RS256, kid `stage2-key-1` |
| `agentcore_audiences` | `["vault-standin"]` | Matches the `--aud` used in `mint-jwt.py` |
| JWT `sub` for UC1 | `uc1-agent` | Matches the Agent Registry entry in `vault_config/main.tf` |
| `optional_authorization_details` | `true` (UC1) | RAR not required until UC2/UC3 |

**Rationale for using the local keypair (not AgentCore Identity or an external OAS):**
For UC1, the workshop teaches *what Vault validates* — the JWT claim structure,
JWKS-based signature verification, and the Agent Registry check. A self-hosted
keypair + OIDC discovery makes the entire trust chain visible and inspectable
(attendees can `cat` the private key, decode the token at jwt.io, and see every
step). This is optimal for a security workshop. The issuer upgrades to AgentCore
Identity or an external OAS in UC2/UC3 when user-delegation claims (OBO) become
relevant — that swap is a config change in `vault_config`, not a rebuild.

**What this means for Oscar (Phase B):**
- Point `vault_oauth_resource_server_config_profile.agentcore` at the issuer/JWKS above
- Register `uc1-agent` in the Agent Registry with the `uc1` policy
- The existing `mint-jwt.py` produces tokens Vault will accept with zero changes
- Same JWT works for both Gateway *and* Vault (parallel paths, not nested)

---

## 2. Deployment prerequisites (the parts still open)

These are the things Stage 3 needs that Stages 0-2 did not:

1. **Vault Enterprise license.** Required for the Agent Registry (beta). You (Oscar) are
   providing this. Decision from design: injected at deploy from a content-team-owned
   secret (e.g. Secrets Manager), NOT bundled per-attendee. Confirm the tier exposes the
   Agent Registry.

2. **Where Vault runs.** Decision: **self-hosted Vault Enterprise on AWS** (hard
   constraint — NOT HCP Vault Dedicated, which runs in HashiCorp's cloud). A **single
   persistent Vault server on a small EC2 instance (or Fargate)** is sufficient for the
   lab — NOT an HA Raft cluster. This keeps "no self-managed Kubernetes cluster" true
   while accepting one Terraform-managed Vault instance. The `infrastructure/modules/
   vault_server/` module is a stub to fill in for this.

3. **The `vault_config` module inputs** (see `vault_config/variables.tf`). You must
   supply:
   - `agentcore_issuer` — the AgentCore Identity issuer (`iss` claim)
   - `agentcore_jwks_url` — the AgentCore Identity JWKS endpoint Vault fetches keys from
   - `agentcore_audiences` — the agent workload audience(s)
   - `rds_endpoint`, `rds_db_name`, `rds_master_username`, `rds_master_user_secret_arn`
   - `bedrock_reader_role_arn` — the IAM role `aws/sts/bedrock-reader` assumes

   > **RESOLVED (Phase A):** the issuer/JWKS values are confirmed — see §1b above. The local Stage 2
   > used a local keypair + gist JWKS as a stand-in *because* we had not yet confirmed
   > the exact AgentCore Identity issuer/JWKS/claim shape for a workload token. Before
   > wiring Vault's OAuth resource server, confirm what AgentCore Identity actually emits
   > (issuer URL, JWKS URL, and whether `sub` carries the agent workload identity). This
   > is the first thing to nail down in Stage 3.

---

## 3. How the agent connects to Vault (what changes vs. Stage 2)

Stage 2's agent tool (`applications/stage0hello/app/stage0hello/main.py`,
`retrieve_from_kb_via_broker` + `_broker_vend`) does: JWT in -> get scoped creds -> use
them for `bedrock:Retrieve`. For Stage 3, only `_broker_vend` changes — swap the
`lambda.invoke` call for a Vault call:

- **Vault presents the JWT directly as the token.** Per `vault_config`, the AgentCore
  JWT is sent as the `X-Vault-Token` header against the OAuth resource-server profile —
  there is no separate Vault login. So the agent reads a Vault credential path
  (`database/creds/uc1-readonly` or `aws/sts/bedrock-reader`) with the JWT as the token.
- The `get_scoped_credentials(jwt)` return shape (`access_key_id`, `secret_access_key`,
  `session_token`, ...) stays the same, so the KB-read code after it is unchanged.

The reference client `applications/vault-standin/broker_client.py` documents this seam:
"In Stage 3 this same method points at Vault's OAuth resource server instead of the
broker Lambda — the agent tool code does not change."

> **Transport caution (learned in Stage 2):** if the Vault endpoint is plain HTTPS, the
> agent can call it directly with `hvac`/`urllib`. If for any reason you route through an
> AWS service (e.g. a Lambda in front of Vault), use **`lambda.invoke`, not a Function
> URL** — the AgentCore Runtime's outbound SigV4 could not satisfy a Function URL's
> auth layer (403 before the function ran). See `RUNBOOK.md` Stage 2 transport lesson.

---

## 4. Suggested Stage 3 order of work

1. **Confirm AgentCore Identity's real issuer / JWKS / claim shape** (the one unproven
   input). Everything else keys off this.
2. **Fill in `infrastructure/modules/vault_server/`** — single EC2/Fargate Vault
   Enterprise, license from Secrets Manager, KMS auto-unseal (`vault_iam` module already
   scopes the KMS + Bedrock-STS assume path).
3. **`terraform apply` `vault_config`** with the real AgentCore issuer/JWKS + RDS +
   `bedrock_reader_role_arn` inputs.
4. **Swap `_broker_vend`** in the agent to call Vault (present JWT -> read
   `aws/sts/bedrock-reader`), leaving `get_scoped_credentials`'s interface intact.
5. **Re-run the Stage 2 proof** (same JWT, same KB question). Diff against the broker
   result to show the stand-in was faithful. Then repeat the negative test — an
   unregistered agent should be blocked by the Vault Agent Registry instead of the
   Lambda allowlist.

---

## 5. What stays the same (do not rebuild)

- **The KB** (`applications/stage1-kb/`, managed Bedrock KB, Meridian corpus) — Vault
  vends creds to read it; the KB itself is unchanged.
- **The agent** (`applications/stage0hello/`) — Strands on AgentCore Runtime, Nova Pro.
  Only `_broker_vend`'s transport changes.
- **The control-objective mapping** (`STAGES.md` traceability table) — Stage 3 just moves
  the checkmarks from stand-ins to real Vault (dynamic secrets, policy+registry, audit).

---

## 6. Open design questions to resolve with the team

- **OBO / UC2-UC3:** UC1 uses the agent's own workload identity. UC2 (user intent) and
  UC3 (privileged write) add the AgentCore on-behalf-of flow + user-context JWTs. The
  `mint-jwt.py` signer already parameterizes `sub`, so a user `sub` needs no code change
  — but the AgentCore OBO token exchange (`GetWorkloadAccessTokenForJWT` +
  `GetResourceOauth2Token`) is not yet wired. See `DESIGN.md` §4.
- **JWKS in the real workshop:** the gist/local-keypair JWKS is a Stage 2 dev shortcut.
  In the finished workshop the JWT/JWKS comes from AgentCore Identity (+ an OIDC IdP for
  users), and the broker is retired. Decide whether the broker survives as an optional
  "how it works under the hood" appendix.
- **`aws-targets.json`** is gitignored (carries the real account id) — each operator's
  deploy target stays local.
