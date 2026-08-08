# Staged build & demonstration plan

Build the workshop in stages. After each stage you can **manually deploy what we've
built to your AWS account and show it does what we claim** — before real Vault
exists. Where a stage needs something Vault will later provide, we use an
AWS-native **stand-in** with the same interface, so the agent code does not change
when real Vault arrives.

**Operating notes for every stage**
- Confirm the active identity first: `aws sts get-caller-identity --profile agentic`
- Every AWS CLI call uses `--profile agentic`.
- Target account: **<ACCOUNT_ID>** (personal default) unless stated otherwise.
- You run the commands in your terminal; the agent hands them over (git/aws/terraform are not run in-sandbox for this project).

---

## What Vault does in UC1 (so we know what to stand in for)

| Vault's real job (UC1) | Stand-in with AWS primitives | Proves |
|---|---|---|
| Validate the AgentCore JWT (JWKS) | AgentCore Runtime's own `customJWTAuthorizer` (inbound auth), or a Lambda validating against the JWKS URL | the workload/user JWT is real, signed, verifiable |
| Agent Registry (is this agent approved?) | Allowlist check in the broker Lambda | the registration concept, minus the beta dependency |
| Mint scoped Bedrock creds | STS `AssumeRole` into a `bedrock-reader` role | no standing privileges — short-lived, real IAM scoping |
| Short-lived DB creds | (deferred — UC1's star is the KB read) | JIT credential issuance |
| Single audit log | CloudWatch Logs / CloudTrail on assume-role + KB calls | the audit story in AWS-native form |

The agent's `vault_client.py` exposes one shape: **JWT in → scoped creds out.** Each
stand-in keeps that shape, so `agent.py` is stable from Stage 1 through Stage 3.

---

## Stage 0 — AgentCore hello-world (no Vault, no KB)

**Goal:** prove AgentCore Runtime works in your account: deploy a trivial Strands
agent, invoke it, confirm it has a workload identity.

**Build (in repo):** `applications/stage0-hello/` — a minimal Strands agent
(`agent.py`) + `requirements.txt` + starter-toolkit entrypoint. Already scaffolded.

**Deploy & invoke (you run):**
```bash
aws sts get-caller-identity --profile agentic          # confirm <ACCOUNT_ID>

cd applications/stage0-hello
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Configure + launch with the AgentCore starter toolkit (builds image via CodeBuild,
# creates the ECR repo + execution role, creates the runtime).
agentcore configure --entrypoint agent.py --name stage0hello --region us-east-1
agentcore launch                                        # uses --profile via AWS_PROFILE
# ^ if the toolkit doesn't read --profile, prefix: AWS_PROFILE=agentic agentcore launch

# Invoke it
agentcore invoke '{"prompt": "say hello and name your workload identity"}'
```

**Demonstrate:**
- `agentcore status` shows the runtime `READY` and prints the **workload identity ARN**.
- `agentcore invoke` returns the agent's reply.

**Stand-in for Vault:** none yet.

---

## Stage 1 — Agent reads the Bedrock KB via a scoped execution role

**Goal:** OBJ-1 (identity) + the KB read path, with the runtime **execution role** as
the scoped credential (the first Vault stand-in).

**Build:** promote `stage0-hello` into `uc1-agent` (already implemented:
`query_knowledge_base` tool). Grant the execution role `bedrock:Retrieve` on the KB.

**Prereq decision:** use an existing Bedrock KB or stand up a fresh one (see open
question in DESIGN §8). Set `BEDROCK_KB_ID` as a runtime env var.

**Deploy & invoke (you run):**
```bash
# Add KB read to the runtime execution role (role ARN from `agentcore status`)
aws iam put-role-policy --profile agentic \
  --role-name <agentcore-exec-role> \
  --policy-name bedrock-kb-read \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:Retrieve"],"Resource":"arn:aws:bedrock:us-east-1:<ACCOUNT_ID>:knowledge-base/<KB_ID>"}]}'

agentcore invoke '{"prompt": "what does the knowledge base say about <topic>?"}'
```

**Demonstrate:** the agent answers from the KB; remove the policy and the same call
is denied — proving enforcement is real, not cosmetic.

**Stand-in for Vault:** the scoped execution role = "Vault vended a Bedrock-scoped credential."

---

## Stage 2 — Insert the credential-broker stand-in (the money stage)

**Goal:** prove the full **present JWT → validated → receive JIT creds** flow that
Vault will perform, without changing the agent.

**Build:** `applications/vault-standin/` — a Lambda (invoked directly via `lambda.invoke`; see Lessons below) that:
1. validates the caller's AgentCore/Cognito JWT against the JWKS URL,
2. checks an allowlist (Agent Registry stand-in),
3. returns short-lived creds via STS `AssumeRole` (dynamic-secrets stand-in),
4. logs every issuance to CloudWatch (audit stand-in).

Point `uc1-agent/vault_client.py` at the broker endpoint instead of Vault. The
`get_*_credentials()` shape is unchanged (JWT in → creds out).

**Demonstrate:** valid JWT → creds + KB answer; forged/expired JWT → 401; agent not on
the allowlist → 403. This is the behaviour Vault will reproduce in Stage 3.

**Stand-in for Vault:** the Lambda = JWT validator + Agent Registry + credential broker + audit.

### Stage 2 — implementation notes (built)

Token model correction (verified against AWS docs): the AgentCore **workload access
token** is AWS-signed, opaque, and first-party-only — NOT a JWT the agent can present
to an external broker. The faithful JWT path is an **inbound OIDC JWT**. To avoid a
Cognito dependency we use **Option B**: a local RSA keypair + a JWKS published to a
raw URL; the broker validates against that JWKS exactly as Vault will (Stage 3).

Built under `applications/vault-standin/`:
- `tools/keygen.sh` + `pem_to_jwks.py` — one-time RSA keypair -> `jwks.json` (kid `stage2-key-1`)
- `tools/mint-jwt.py` — signs an RS256 JWT (`sub`/`aud`/`scope`/`iss` all parameters;
  Stage 2 default `sub=uc1-agent`; UC2 will mint a user `sub` with no code change)
- `broker/handler.py` — Lambda: validate JWT via JWKS -> allowlist (`ALLOWED_SUBS`) ->
  `sts:AssumeRole` into a scoped role -> return short-lived creds; one audit line per decision
- `broker/deploy.sh` — vended role (bedrock:Retrieve on KB QLKOTZM2GC), Lambda role,
  packaged Lambda, IAM-auth Function URL
- `broker_client.py` — agent-side `get_scoped_credentials(jwt)`; shape-compatible with the
  Stage 3 Vault client (swap endpoint, not agent logic)

Secrets: `private.pem` and minted `*.jwt` are gitignored — only public `jwks.json` is shared.

### Stage 2 — PROVEN (Aug 8 2026) + lessons learned

Proven end-to-end in account <ACCOUNT_ID>: agent → broker → scoped creds → KB read.
Both paths confirmed — allow (`sub=uc1-agent` → vended creds → Meridian SLA answer)
and deny (unregistered `sub` → HTTP 403 `"not registered/approved"`). Broker logged
`{"decision": "allow", "sub": "uc1-agent", ...}`.

**Transport decision (important for Stage 3 and any agent→service call):**
Use **direct `lambda.invoke`**, NOT a Lambda Function URL, when the caller is an
AgentCore Runtime agent. A Function URL adds its own HTTP-auth layer; the runtime's
outbound call returned **403 before the function ever ran**, under both `AWS_IAM` and
`NONE` auth types, and burned hours. `lambda.invoke` is a native signed AWS API call
the runtime already makes correctly (same path as its working Bedrock/STS calls). Clean
layering: **transport auth = IAM** (agent execution role holds `lambda:InvokeFunction`),
**business auth = the JWT** (broker validates via JWKS + allowlist). The agent's
`get_scoped_credentials(jwt)` interface is unchanged, so Stage 3's Vault swap is still
just an endpoint change.

**Three gotchas that cost time (avoid in later stages):**
1. **The AgentCore CLI does NOT inject `agentcore.json` `environmentVariables` onto the
   runtime** (`get-agent-runtime` returned `environmentVariables: null`). Put runtime
   config in code (a module-level default) or find the correct CLI mechanism — not
   `agentcore.json`.
2. **macOS-built native wheels fail on Lambda** with `invalid ELF header`
   (`cryptography`/`cffi` ship compiled binaries). Pin the pip install to the Lambda
   platform: `--platform manylinux2014_x86_64 --python-version 3.12 --implementation cp
   --only-binary=:all:`.
3. **Lambda Function URL 403-before-function** is opaque (no log group until the function
   actually runs). If you see 403 with no invocation log, suspect the URL auth layer, not
   the function — and prefer `lambda.invoke` to sidestep it entirely.

**Deploy-script robustness fixes now baked into `broker/deploy.sh`:**
- Create the Lambda role BEFORE the vended role (whose trust policy names the Lambda
  role as principal — AWS rejects a trust policy referencing a non-existent principal).
- `aws lambda wait function-updated` between `update-function-code` and
  `update-function-configuration` (else `ResourceConflictException: update in progress`).
- Linux-platform wheel pin (gotcha 2).
- `lambda:InvokeFunction` grant on the agent execution role (transport auth).


---

## Stage 3 — Swap in real Vault Enterprise

**Goal:** the real thing; Stages 1-2 predicted it.

**Build:** deploy self-hosted Vault Enterprise (license from Oscar), apply the
`vault_config` module (OAuth resource server → AgentCore JWKS, `uc1-readonly`,
`aws/sts/bedrock-reader`, `uc1` policy, `vault_agent_registration.uc1`). Point the
agent at the Vault OAuth resource server endpoint.

**Demonstrate:** same JWT, same agent code, now brokered by real Vault. Diff against
Stage 2 to show the stand-in was faithful.

**Stand-in for Vault:** none — this is Vault.

---

## Traceability to control objectives

| Stage | OBJ-1 identity | OBJ-2 no standing creds | OBJ-4 point-of-use enforcement | OBJ-5 audit |
|---|---|---|---|---|
| 0 | ✓ (workload identity) | — | — | — |
| 1 | ✓ | ✓ (STS-backed exec role) | ✓ (IAM policy) | partial (CloudTrail) |
| 2 | ✓ | ✓ (STS AssumeRole) | ✓ (broker authz) | ✓ (broker logs) |
| 3 | ✓ | ✓ (Vault dynamic secrets) | ✓ (Vault policy + registry) | ✓ (Vault audit) |
