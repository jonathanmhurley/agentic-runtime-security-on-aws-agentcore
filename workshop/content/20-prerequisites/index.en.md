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

## Vault Enterprise license

A **HashiCorp Vault Enterprise license** is required for the Agent Registry (beta)
and the OAuth resource server features. For this workshop, the license is
pre-provisioned — you do not need to obtain one separately.

> No IVIA/IBM licensing is needed in this edition.

## Version pinning

This workshop is validated against pinned versions. Do not float to `latest`.
See the "Tested against" block in `docs/DESIGN.md` §7 for the exact versions.

## Clone the workshop repository

All workshop code, deployment scripts, and configuration files live in a single Git
repository. Clone it before starting:

```bash
git clone https://github.com/jonathanmhurley/agentic-runtime-security-on-aws-agentcore.git
cd agentic-runtime-security-on-aws-agentcore
```

## Install the AgentCore CLI

```bash
# CloudShell: home directory is small (~1GB). Install to /tmp (larger ephemeral volume).
rm -rf ~/.npm/_cacache                     # clear stale cache if present
export NPM_CONFIG_PREFIX=/tmp/npm-global
export PATH="/tmp/npm-global/bin:$PATH"

npm install -g @aws/agentcore
agentcore --version    # expect 0.27.x or later
```

> **CloudShell timeout note:** `/tmp` is ephemeral — if your CloudShell session times
> out (~20 min idle), re-run the install commands above. Your repo clone and home
> directory files persist across timeouts.

## Install uv (Python package manager)

The AgentCore CLI uses `uv` to manage Python dependencies during deploy:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source $HOME/.local/bin/env
uv --version    # expect 0.6.x or later
```

All subsequent steps assume you are working from the repository root directory.
