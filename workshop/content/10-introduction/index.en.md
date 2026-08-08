---
title: 'Introduction'
weight: 10
---

## The problem

AI agentic systems break assumptions security tooling relied on for two decades. Agents are not users and not classic workloads — sometimes acting on behalf of a user, sometimes autonomously, with the boundary moving request to request. Standing credentials sprawl; and "which user authorized this action?" becomes unanswerable across IdP, IAM, and database logs that share no correlation key.

The agentic threat model spans three trust planes at once — user identity, workload (agent) identity, and the data-plane credential actually presented. In this edition, **AgentCore Identity issues a single user-context JWT** that carries user identity end-to-end, so the three planes are unified by one token rather than reconstructed after the fact.
