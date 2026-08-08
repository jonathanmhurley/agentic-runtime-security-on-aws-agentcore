---
title: 'Prerequisites'
weight: 20
---

## Accounts & access

- AWS account with **Amazon Bedrock AgentCore** enabled (`--profile agentic`).
- Bedrock model access: `us.amazon.nova-pro-v1:0` (Nova Pro via CRIS) and `amazon.nova-2-multimodal-embeddings-v1:0` (us-east-1, for the KB).

## License

- **HashiCorp Vault Enterprise license** — required for the Agent Registry (beta). Provided by the content team and injected at deploy from a content-team-owned secret. Attendees do not supply their own.

> No IBM/IVIA licensing in this edition.

## Version compatibility

This workshop is validated only against pinned versions (Vault Enterprise + AgentCore SDK). See the "Tested against" block in the design doc. The Agent Registry is **beta** — its API may change on newer Vault builds.
