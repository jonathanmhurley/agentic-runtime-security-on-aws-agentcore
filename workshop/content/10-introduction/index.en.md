---
title: 'Introduction'
weight: 10
---

## The problem

Agentic AI blurs the lines between user identity, workload identity, and data-plane credentials — three concerns that traditional security tooling has handled independently. Agents are neither users nor classic workloads because the same agent may act on behalf of Alice in one request and Bob in the next, yet authorization, attribution, and audit must be per-request, not per-agent. Without such controls, credentials outlive their purpose and audit trails fragment — with no way to answer "on whose behalf did this agent act, and what did it do?" This workshop addresses that gap — scoping credentials to each request and tracing every agent action back to the authorizing user.

The core difficulty is that these three planes — user identity, workload identity, and the data-plane credential actually presented — have traditionally lived in separate systems and not needed to be linked. This workshop links them — the [AgentCore Identity](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/on-behalf-of-token-exchange.html) On-Behalf-Of token exchange carries user identity through the agent and into Vault, unifying all three planes by one token rather than reconstructing the chain after the fact.
