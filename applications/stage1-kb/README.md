# stage1-kb — managed Bedrock Knowledge Base for Stage 1

A fully-managed Bedrock KB (zero-config embeddings) over a small fictional corpus
(Meridian Freight Logistics). Managed type chosen deliberately: no AOSS/vector
store to operate — the workshop teaches agent security, not RAG internals.

## Corpus
Three docs about the fictional **Meridian Freight Logistics** so KB answers are
unmistakably grounded (a correct answer could only come from the KB):
- `corpus/meridian-overview.md` — company, RapidLane, Compass dispatch
- `corpus/meridian-sla.md` — 6-hour SLA, credit tiers, priority scores
- `corpus/meridian-support.md` — support hours, escalation tiers, Claims team

Good verification questions:
- "What is RapidLane's same-day SLA?" → 6 hours if booked before 11 AM
- "What credit applies if a shipment is more than 24 hours late?" → 100% of base rate
- "What prefix do Tier 3 lost-freight case codes use?" → MFL-CLM-

## Use
```bash
bash create-kb.sh        # prints KB_ID
# put KB_ID into ../stage0hello/agentcore/agentcore.json (environmentVariables.BEDROCK_KB_ID)
# grant exec role bedrock:Retrieve on the KB (see docs/STAGES.md Stage 1)
bash teardown-kb.sh      # when done
```

All calls use `--profile agenticvault`, region `us-east-1`, your account (derived at runtime via STS).
