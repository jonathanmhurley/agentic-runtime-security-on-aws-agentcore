---
title: 'Prerequisites'
weight: 20
---

## AWS account requirements

- **Amazon Bedrock** enabled with model access for:
  - `amazon.nova-pro-v1:0` (Nova Pro via CRIS — agent reasoning)
  - `amazon.nova-2-multimodal-embeddings-v1:0` (managed KB embeddings, us-east-1)
- **Amazon Bedrock AgentCore** enabled (Runtime + Gateway)
- **AWS Lambda**, **IAM**, **EC2**, **S3**, **STS** access

## Tools required

- **Node.js 20+** — the AgentCore CLI (`npm install -g @aws/agentcore`)
- **Python 3.10+** with `pyjwt` and `cryptography` — for JWT minting tools
- **AWS CLI v2** with a configured profile for the target account
- **Terraform 1.10+** — for applying the Vault configuration
- **HashiCorp Vault CLI** — for interacting with the deployed Vault instance
- **uv** — Python package manager (used by `agentcore deploy`)

## Vault Enterprise license

A **HashiCorp Vault Enterprise license** is required for the Agent Registry (beta)
and the OAuth resource server features. For this workshop, the license is
pre-provisioned — you do not need to obtain one separately.

> No IVIA/IBM licensing is needed in this edition.

## Version pinning

This workshop is validated against pinned versions. Do not float to `latest`.
See the "Tested against" block in `docs/DESIGN.md` §7 for the exact versions.

## CloudShell setup

[Open AWS CloudShell](https://console.aws.amazon.com/cloudshell/home?region=us-east-1) in your workshop account, then run:

Clone the repo and run the setup script. It installs the AgentCore CLI, `uv`,
and creates the deployment target config for your account:

```bash
git clone https://github.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore.git
cd agentic-runtime-security-on-aws-agentcore
bash scripts/setup-cloudshell.sh
export PATH="/tmp/npm-global/bin:$HOME/.local/bin:$PATH"
```

> **CloudShell timeout note:** `/tmp` is ephemeral. If your CloudShell session
> times out (~20 min idle), re-run `bash scripts/setup-cloudshell.sh` and the
> `export PATH` line. Your repo clone and home directory files persist.

<details>
<summary>What the setup script does (expand for details)</summary>

1. Installs the AgentCore CLI to `/tmp/npm-global` (CloudShell home is ~1GB, too small for a global npm install)
2. Installs `uv` (Python package manager used by `agentcore deploy`)
3. Creates `agentcore/aws-targets.json` in `applications/stage0hello/` with your account ID and `us-east-1`

</details>

All subsequent steps assume you are working from the repository root directory.
<!-- build trigger -->
