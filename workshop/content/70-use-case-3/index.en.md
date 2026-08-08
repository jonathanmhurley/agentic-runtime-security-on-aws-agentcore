---
title: 'Use Case 3 — Privileged write & single-plane audit'
weight: 70
---

A privileged-write agent. The OBO-scoped token authorizes a write, and the **single hash-chained Vault audit log** records agent id + resolved user id + JWT + lease in one stream — answering "which user caused this, under what authorization, for which task, and when?" without a multi-plane JOIN. (CIBA out-of-band approval from the reference arch is replaced by AgentCore OBO consent.)
