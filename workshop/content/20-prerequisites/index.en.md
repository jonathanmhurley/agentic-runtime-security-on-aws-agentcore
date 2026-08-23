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
