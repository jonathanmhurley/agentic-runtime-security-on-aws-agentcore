---
title: 'Use Case 3 — Privileged write & single-plane audit'
weight: 70
---

> **Status: not yet built.** Requires UC2 (OBO) + real Vault Enterprise (Stage 3).

## What UC3 will demonstrate

A privileged-write agent. The OBO-scoped token authorizes a write, and the
**single hash-chained Vault audit log** records agent id + resolved user id + JWT +
lease in one stream — answering "which user caused this, under what authorization,
for which task, and when?" No multi-plane JOIN needed (the JWT carries resolved
identity end-to-end).
