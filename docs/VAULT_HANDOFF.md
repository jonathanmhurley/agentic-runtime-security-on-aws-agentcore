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
| `vault_agent_registration.uc1` | Registers `uc1-agent` as an approved identity (BETA, Enterprise). In the proven flow, the GA JWT auth method's `bound_subject` parameter serves as the functional allowlist instead. | broker allowlist (`ALLOWED_SUBS`) |

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


## 1c. Phase C COMPLETE — Vault config applied (Aug 14, 2026)

All Vault Enterprise resources are configured on a dev-mode instance (2.0.4+ent):
- OAuth resource server profile `agentcore` trusting our GitHub-hosted JWKS ✓ (configured, but entity-alias lookup broken in 2.0.4 — not used for token validation. GA JWT auth `auth/jwt/` is the working path.)
- Agent Registry: `uc1-agent` registered (entity `f38e8fd6-...`, reg ID `9a57ce93-...`) ✓
- AWS secrets engine + `bedrock-reader` role ✓
- `uc1` policy + identity entity ✓
- Audit device (stdout, JSON) ✓

**Correct API paths discovered (different from earlier assumptions):**
- Activation: `PUT sys/activation-flags/oauth-resource-server/activate`
- Profile: `PUT sys/config/oauth-resource-server/:name` (no `profiles/` segment)
- Agent Registry register: `PUT agent-registry/register` (not `agent-registry/registration`)
- Agent Registry read: `GET agent-registry/registration/display-name/:name`

**Next: Phase D** — swap the agent's credential path to call Vault directly with the JWT.

---

## 1d. Phase D PROVEN — JWT → Vault → scoped STS creds (Aug 23, 2026)

**Stage 3 is fully proven.** The Vault Agentic pattern works end-to-end:
- JWT (RS256, `sub: uc1-agent`, `jti` included) → `auth/jwt/login` validates via JWKS
- Vault issues token with `uc1` policy (auto-creates entity alias)
- `vault read aws/sts/bedrock-reader` → scoped STS creds (15m TTL)
- **Negative test:** `sub: not-registered` → `"invalid subject (sub) claim"` (denied)

**Design decision:** uses the GA **JWT auth method** (`auth/jwt/`), NOT the beta OAuth
Resource Server. The OAuth RS's entity-alias lookup has an undocumented issue in 2.0.4
where pre-created aliases are never found (`"no alias found / error looking up entity"`)
regardless of creation method. This is a beta-feature gap to resolve with HashiCorp for
UC2/UC3 (where RAR claims add value). For UC1, the JWT auth method provides the same
security controls (JWKS validation, `bound_subject` = allowlist, scoped policies) and is
fully GA.

**Key requirements discovered during implementation:**
- JWT must include a `jti` claim (Vault 2.0.4 schema validation requires it)
- `aws/sts/<role>` paths require `update` capability in the policy (not just `read`)
- Vault dev-mode EC2 needs IP-restricted SG + `auto-delete:no` tag to survive account
  security automation (Palisade/Epoxy)

See `workshop/content/55-vault-credentials/` for the attendee-facing workshop page.

---

## 2. Deployment prerequisites (mostly RESOLVED)

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
   - `bedrock_reader_role_arn` — the IAM role `aws/sts/bedrock-reader` assumes

   > **RESOLVED (Phase A):** the issuer/JWKS values are confirmed — see §1b above. The local Stage 2
   > used a local keypair + gist JWKS as a stand-in *because* we had not yet confirmed
   > the exact AgentCore Identity issuer/JWKS/claim shape for a workload token. Before
   > wiring Vault's OAuth resource server, confirm what AgentCore Identity actually emits
   > (issuer URL, JWKS URL, and whether `sub` carries the agent workload identity). This
   > is the first thing to nail down in Stage 3.

---

## 3. How the agent connects to Vault (what changes vs. Stage 2)

The proven UC2 agent tool is `retrieve_from_kb_as_user` in
`applications/stage0hello/app/stage0hello/main.py`. It performs the full chain using
`urllib.request` for direct HTTP calls to Vault:

1. OBO exchange via `IdentityClient.get_resource_oauth2_token()` to get a user-scoped JWT
2. `POST` to `auth/jwt/login` with `role` + `jwt` parameters (GA JWT auth method)
3. Vault returns a scoped token with per-user policies
4. `POST` to `aws/sts/bedrock-reader` with the Vault token to get STS creds
5. Use the STS creds to call `bedrock:Retrieve` on the KB

> **Note:** The original design described presenting the JWT directly as `X-Vault-Token`
> against the OAuth resource-server profile (no login round-trip). This is the beta path
> and is broken in Vault 2.0.4 (entity-alias lookup failure). The GA JWT auth method
> (`auth/jwt/login`) adds one round-trip but is fully supported and auto-creates entities.

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
