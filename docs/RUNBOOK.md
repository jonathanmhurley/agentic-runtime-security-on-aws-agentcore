# Runbook — recreate the proven phases (Stages 0-2)

This is the authoritative, tested command sequence to recreate everything proven so
far, from a clean checkout, in your own AWS account. These are the **actual commands
used**, not the aspirational `deploy-workshop.sh --tier N` flow in the top-level README
(that tiered flow describes the *eventual* packaged workshop and is not built yet).

Stages 0-2 were proven end-to-end on 2026-08-08. Stage 3 (real Vault) is the next
milestone — see `VAULT_HANDOFF.md`.

---

## 0. Prerequisites (one-time)

- **Node.js 20+** — the AgentCore CLI is a Node package.
- **Python 3.10+** and **openssl** — for the local JWT-minting tools (Stage 2).
- **AWS account** with Bedrock AgentCore enabled, and Bedrock model access for
  `amazon.nova-pro-v1:0` and `amazon.nova-2-multimodal-embeddings-v1:0` (us-east-1).
- **AWS CLI** with a profile pointing at that account.

```bash
# Install the AgentCore CLI (Node.js, NOT the Python starter toolkit).
npm install -g @aws/agentcore
agentcore --version          # tested against 0.26.0

# Configure your AWS profile and set a default region (the CLI needs one).
# Substitute your own profile name; this repo used "agenticvault".
export AWS_PROFILE=agenticvault
aws configure set region us-east-1 --profile "$AWS_PROFILE"
aws sts get-caller-identity --profile "$AWS_PROFILE"   # confirm the RIGHT account
```

> **Credential-conflict gotcha:** if your shell has BOTH `AWS_PROFILE` and
> `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` set, the AgentCore CLI warns and may pick
> the wrong identity. Clear the loose env keys so only the profile is used:
> `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`

---

## Stage 0 — AgentCore hello-world

Proves AgentCore Runtime deploys and is invokable in your account, and that the agent
has a workload identity.

The project already exists in this repo at `applications/stage0hello/` (created with
`agentcore create --name stage0hello --framework Strands --protocol HTTP
--model-provider Bedrock --memory none`). To recreate from scratch you would run that
`create`; to use what's here, just deploy it.

```bash
cd applications/stage0hello

# The scaffold defaults to a Claude model; this repo already sets Nova Pro via CRIS
# in app/stage0hello/model/load.py:
#   BedrockModel(model_id="us.amazon.nova-pro-v1:0")

AWS_PROFILE=agenticvault agentcore validate
AWS_PROFILE=agenticvault agentcore deploy      # CDK: bootstrap -> synth -> deploy (~3 min first run)
AWS_PROFILE=agenticvault agentcore status      # expect Runtime: READY + a workload identity ARN
AWS_PROFILE=agenticvault agentcore invoke "say hello and name your model"
```

**Proven:** Runtime READY, workload identity ARN present, invoke returns a Nova reply.

> **CLI gotchas seen here:**
> - Commands are `agentcore create/deploy/invoke/status` (Node CLI). NOT `agentcore
>   configure/launch` — those are the *Python* starter toolkit, a different tool.
> - On first deploy after a CLI update the CLI pins its CDK dependency versions and runs
>   `npm install` in `agentcore/cdk`. Leave `disableDependencyManagement` at default.

---

## Stage 1 — Agent reads a managed Bedrock Knowledge Base via a scoped execution role

Proves OBJ-1 (agent identity) + the KB read path, with the runtime **execution role**
as the scoped credential (the first Vault stand-in).

### 1a. Stand up the managed KB (fictional Meridian corpus)

```bash
cd applications/stage1-kb
bash create-kb.sh        # idempotent: S3 bucket + corpus upload + KB service role +
                         # managed KB + S3 data source + ingestion. Prints KB_ID.
```

The script derives the account from STS and uses `--profile agenticvault`, region
us-east-1. It waits for the KB to reach ACTIVE and the data source to reach AVAILABLE
before starting ingestion. Note the printed `KB_ID`. Teardown later with
`bash teardown-kb.sh`.

> **Managed-KB gotchas seen here:**
> - A `MANAGED` KB requires the data-source shape
>   `type: MANAGED_KNOWLEDGE_BASE_CONNECTOR` with `connectorParameters` (bucket **name**,
>   not ARN) — NOT the self-managed `S3`/`s3Configuration` shape.
> - KB and data-source creation are async; create-kb.sh polls for ACTIVE/AVAILABLE.

### 1b. Wire the KB into the agent + grant the execution role

The agent's KB tool (`applications/stage0hello/app/stage0hello/main.py`,
`retrieve_from_kb`) reads `BEDROCK_KB_ID`. **The AgentCore CLI does NOT inject
`agentcore.json` env vars onto the runtime** (confirmed: `get-agent-runtime` returns
`environmentVariables: null`). So the KB id is set as a code fallback:

```python
# app/stage0hello/model/../main.py
_DEFAULT_KB_ID = "QLKOTZM2GC"   # <- replace with YOUR KB_ID from create-kb.sh
BEDROCK_KB_ID = os.getenv("BEDROCK_KB_ID") or _DEFAULT_KB_ID
```

Find the runtime execution role and grant it `bedrock:Retrieve` on your KB:

```bash
# Execution role ARN (agentcore status does NOT print it; read it from the runtime):
aws bedrock-agentcore-control get-agent-runtime \
  --agent-runtime-id <RUNTIME_ID> --profile agenticvault --region us-east-1 \
  --query roleArn --output text
# RUNTIME_ID is the id in the ARN from `agentcore status`, e.g. stage0hello_stage0hello-XXXX

aws iam put-role-policy --profile agenticvault \
  --role-name <EXEC_ROLE_NAME> \
  --policy-name stage1-bedrock-kb-read \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:Retrieve"],"Resource":"arn:aws:bedrock:us-east-1:<ACCOUNT_ID>:knowledge-base/<KB_ID>"}]}'
```

### 1c. Confirm ingestion, redeploy, invoke

```bash
aws bedrock-agent list-ingestion-jobs --knowledge-base-id <KB_ID> --data-source-id <DS_ID> \
  --profile agenticvault --region us-east-1 --query "ingestionJobSummaries[0].status" --output text
# want COMPLETE

cd ../stage0hello
AWS_PROFILE=agenticvault agentcore deploy
AWS_PROFILE=agenticvault agentcore invoke "What is RapidLane's same-day SLA?"
```

**Proven:** the agent answers "6 hours if booked before 11:00 AM" — a fact that exists
only in the KB corpus, so a correct answer proves: agent identity -> scoped exec-role
credential -> `bedrock:Retrieve` -> KB. Remove the inline policy and the same query
fails (proof the credential is real enforcement).

---

## Stage 2 — Credential broker (the Vault stand-in)

Proves the full **present JWT -> validate via JWKS -> allowlist -> vend scoped creds**
flow that real Vault performs in Stage 3, without changing the agent.

### 2a. Generate the keypair + publish the JWKS

```bash
cd applications/vault-standin
bash tools/keygen.sh          # -> private.pem (LOCAL, gitignored) + public.pem + jwks.json
cat jwks.json
```

Publish `jwks.json` to a public raw URL the broker can fetch. Fastest is a **public
GitHub gist** (filename `jwks.json`), then take its **Raw** URL and strip the revision
SHA so it always serves latest:
`https://gist.githubusercontent.com/<you>/<id>/raw/jwks.json`

> Copy `jwks.json` straight from the file — do not retype it (a single altered char in
> `n` breaks signature validation). Verify the published copy:
> `curl -s <RAW_URL> | python3 -m json.tool`

Install the local minting deps (Homebrew Python blocks system installs — use a venv or
`--user --break-system-packages`):

```bash
python3 -m pip install --user --break-system-packages pyjwt cryptography
python3 -c "import jwt; print('ok', jwt.__version__)"
```

### 2b. Deploy the broker

```bash
JWKS_URL="https://gist.githubusercontent.com/<you>/<id>/raw/jwks.json" \
ISS="https://gist.githubusercontent.com/<you>/<id>/raw/jwks.json" \
bash broker/deploy.sh
```

`deploy.sh` (idempotent) creates: the Lambda role FIRST, then the vended role
(`Stage2VendedKBReadRole`, scoped to `bedrock:Retrieve` on the KB) that trusts it; packages
the Lambda with **Linux x86_64 wheels**; creates the function; and grants the **agent
execution role** `lambda:InvokeFunction` on the broker. `ISS` must be byte-for-byte the
value you mint tokens with.

> **Broker deploy gotchas (all fixed in deploy.sh, noted so you understand them):**
> - Role ordering: a trust policy naming a not-yet-existent principal is rejected — Lambda
>   role must exist before the vended role that trusts it.
> - `cryptography`/`cffi` are native wheels; macOS builds fail on Lambda with
>   `invalid ELF header`. deploy.sh pins `--platform manylinux2014_x86_64 --python-version
>   3.12 --implementation cp --only-binary=:all:`.
> - `aws lambda wait function-updated` sits between code and config updates to avoid
>   `ResourceConflictException`.

### 2c. Mint a JWT and invoke through the agent

```bash
JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "https://gist.githubusercontent.com/<you>/<id>/raw/jwks.json" \
  --scopes kb:read --kid stage2-key-1 --ttl 900)"

cd ../stage0hello
AWS_PROFILE=agenticvault agentcore invoke "{\"prompt\": \"Use the broker to look up the RapidLane SLA\", \"jwt\": \"$JWT\"}"
```

Confirm the broker logged its decision:

```bash
aws logs tail /aws/lambda/stage2-cred-broker --profile agenticvault --region us-east-1 \
  --since 5m --format short | grep broker_decision
# expect: {"decision": "allow", "sub": "uc1-agent", ...}
```

**Negative test** (proves the allowlist enforces — this is the Agent Registry stand-in):

```bash
cd ../vault-standin
BADJWT="$(python3 tools/mint-jwt.py --sub not-registered --aud vault-standin \
  --iss "https://gist.githubusercontent.com/<you>/<id>/raw/jwks.json" \
  --scopes kb:read --kid stage2-key-1 --ttl 900)"
# Call the broker directly with this token -> expect HTTP 403 "not registered/approved".
```

**Proven:** allow path (`uc1-agent` -> vended creds -> Meridian SLA answer) and deny
path (unregistered sub -> 403).

> **CRITICAL transport lesson:** the agent calls the broker via **direct
> `lambda.invoke`**, NOT a Lambda Function URL. A Function URL adds its own HTTP-auth
> layer that the AgentCore Runtime's outbound call could not satisfy — it returned **403
> before the function ever ran**, under both `AWS_IAM` and `NONE` auth types, and cost
> hours. `lambda.invoke` is a native signed AWS API call the runtime already makes
> (same path as its working Bedrock/STS calls). Layering: transport auth = IAM (exec
> role `lambda:InvokeFunction`), business auth = the JWT. **Use this pattern for any
> agent -> service call, including the Stage 3 Vault call if it is not plain HTTPS.**

---


---

## Stage 2b — AgentCore Gateway (native proof-of-value)

Proves the same flow as Stage 2 (present JWT → validate → scoped credential → KB read)
but using the **native AgentCore Gateway primitive** instead of a hand-built broker Lambda.
Directly answers Welly's "prove it inside AgentCore Runtime / Gateway."

### 2b-1. Publish OIDC discovery to the repo

The `.well-known/openid-configuration` and `jwks.json` are already committed to
`applications/vault-standin/` and served via the public GitHub raw URL:

```
Discovery URL: https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin/.well-known/openid-configuration
Issuer:        https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin
JWKS:          https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin/jwks.json
```

> The repo must be **public** for these raw URLs to be fetchable by Gateway.

### 2b-2. Add a Gateway to the agent project

```bash
cd applications/stage0hello
agentcore add gateway \
  --name workshop-gateway \
  --authorizer-type CUSTOM_JWT \
  --discovery-url "https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin/.well-known/openid-configuration" \
  --allowed-audience vault-standin \
  --runtimes stage0hello
agentcore deploy
agentcore status    # expect Gateway: Deployed
```

### 2b-3. Deploy the Gateway KB target Lambda

```bash
cd applications/gateway-kb-target
bash deploy.sh
```

This creates a thin Lambda wrapping `bedrock:Retrieve`, grants the Gateway's IAM role
`lambda:InvokeFunction` on it, and registers it as a Gateway target with tool schema
`kb-retrieve___retrieve_from_kb`. If `create-gateway-target` fails on permission
propagation, wait 15s and retry the `create-gateway-target` call from the script output.

### 2b-4. Mint a JWT and invoke through the Gateway

```bash
cd applications/vault-standin
JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin" \
  --scopes kb:read --kid stage2-key-1 --ttl 900)"

curl -s -X POST "https://<GATEWAY_ID>.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"kb-retrieve___retrieve_from_kb","arguments":{"query":"RapidLane SLA"}},"id":1}' | python3 -m json.tool
```

Replace `<GATEWAY_ID>` with the ID from `agentcore status` or:
```bash
aws bedrock-agentcore-control get-gateway --gateway-identifier <ID> --query gatewayUrl --output text
```

Or just run from the repo root:
```bash
bash demo.sh "What is RapidLane's same-day SLA?"
```

**Proven:** the Meridian SLA (6 hours if booked before 11 AM) comes through the Gateway.
JWT validated via OIDC discovery + JWKS. Caller never held `bedrock:Retrieve` — Gateway
brokered it via `GATEWAY_IAM_ROLE`. Same principle as Vault vending a scoped credential,
native AgentCore primitive.


---

## Stage 3 — Real Vault Enterprise (JWT auth + dynamic credentials)

Proves the full Vault Agentic pattern: JWT → Vault validates → scoped STS credentials
vended. Same JWT as Stages 2/2b, now brokered by real HashiCorp Vault Enterprise.

### 3-1. Deploy Vault Enterprise (dev mode, IP-restricted)

```bash
cd infrastructure/modules/vault_server
KEY_NAME=vault-workshop bash deploy-vault-dev.sh
# Prints VAULT_ADDR + VAULT_TOKEN. Wait ~90s for user-data to finish.
export VAULT_ADDR=http://<IP>:8200
export VAULT_TOKEN=workshop-root-token
vault status
```

### 3-2. Apply the Vault configuration

```bash
cd infrastructure/modules/vault_config
rm -f terraform.tfstate terraform.tfstate.backup
terraform apply -auto-approve
```

Then configure the JWT auth method (not yet in Terraform — run manually):

```bash
vault auth enable jwt
vault write auth/jwt/config \
  jwks_url="https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin/jwks.json" \
  default_role="uc1-agent"
vault write auth/jwt/role/uc1-agent \
  role_type="jwt" \
  bound_audiences="vault-standin" \
  bound_subject="uc1-agent" \
  user_claim="sub" \
  token_policies="uc1" \
  token_ttl="15m"
```

Configure the AWS secrets engine credentials + trust policy:

```bash
vault write aws/config/root \
  access_key="$(aws configure get aws_access_key_id --profile agenticvault)" \
  secret_key="$(aws configure get aws_secret_access_key --profile agenticvault)" \
  region=us-east-1

aws iam put-user-policy --user-name hurleyjm --profile agenticvault \
  --policy-name assume-vended-role \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"arn:aws:iam::<ACCOUNT_ID>:role/Stage2VendedKBReadRole"}]}'

aws iam update-assume-role-policy --profile agenticvault \
  --role-name Stage2VendedKBReadRole \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["arn:aws:iam::<ACCOUNT_ID>:role/Stage2BrokerLambdaRole","arn:aws:iam::<ACCOUNT_ID>:user/hurleyjm"]},"Action":"sts:AssumeRole"}]}'
```

### 3-3. Prove the flow (allow + deny)

```bash
cd applications/vault-standin

# Mint a JWT (includes jti — required by Vault 2.0.4)
JWT="$(python3 tools/mint-jwt.py --sub uc1-agent --aud vault-standin \
  --iss "https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin" \
  --scopes kb:read --kid stage2-key-1 --ttl 900)"

# Authenticate + read scoped creds in one shot
VAULT_TOKEN="$(vault write -field=token auth/jwt/login role=uc1-agent jwt="$JWT")" \
  vault read aws/sts/bedrock-reader
# Expected: STS creds, TTL 15m, assumed-role/Stage2VendedKBReadRole

# Negative test — unregistered agent denied
BADJWT="$(python3 tools/mint-jwt.py --sub not-registered --aud vault-standin \
  --iss "https://raw.githubusercontent.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore/main/applications/vault-standin" \
  --scopes kb:read --kid stage2-key-1 --ttl 900)"
vault write auth/jwt/login role=uc1-agent jwt="$BADJWT"
# Expected: error "invalid subject (sub) claim"
```

**Proven:** JWT → Vault validates (JWKS + bound_subject) → entity + uc1 policy → scoped
STS creds. Unregistered agents denied. Same security controls as the Stage 2 broker,
now on real Vault Enterprise.

> **Lesson:** use the GA **JWT auth method** (`auth/jwt/`), not the beta OAuth Resource
> Server. The OAuth RS has an undocumented alias-lookup issue in 2.0.4 where pre-created
> entity aliases are never found ("no alias found / error looking up entity"). The JWT
> auth method auto-creates aliases on first login and is fully GA. Same JWT, same JWKS,
> same security story — one extra login step that makes the authentication visible.

## Quick reference — what's proven and where it lives

| Stage | Proves | Key files | Deploy |
|---|---|---|---|
| 0 | AgentCore runs, agent identity | `applications/stage0hello/` | `agentcore deploy` |
| 1 | Scoped-cred KB read (OBJ-1, OBJ-2, OBJ-4) | `stage0hello/app/.../main.py`, `applications/stage1-kb/` | `create-kb.sh` + IAM grant + `agentcore deploy` |
| 2 | JWT -> validate -> allowlist -> vend (Vault-shape via Lambda broker) | `applications/vault-standin/` | `broker/deploy.sh` |
| **2b** | **Same flow, native Gateway** (recommended proof) | `applications/gateway-kb-target/`, Gateway config | `gateway-kb-target/deploy.sh` + `demo.sh` |
| **3** | **Real Vault Enterprise** — JWT auth + dynamic STS creds + deny test | `infrastructure/modules/vault_config/`, `vault_server/` | `deploy-vault-dev.sh` + `terraform apply` + JWT auth CLI |

Tested-against versions are in `DESIGN.md` §7. Stage 3 (real Vault) is in `VAULT_HANDOFF.md`.
