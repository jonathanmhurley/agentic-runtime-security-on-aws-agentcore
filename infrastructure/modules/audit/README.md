# Module: audit

**Simplified.** The reference arch's three-plane Athena JOIN (IVIA + Vault + pgaudit) collapses to a **single hash-chained Vault audit log** — the JWT carries resolved user identity end-to-end, so one stream answers user + agent + authorization + lease. A light pgaudit reference on RDS is retained so the data-plane record can be lined up with the Vault lease, but the heavy Athena correlation module is retired.

**Status:** stays (heavily simplified).
