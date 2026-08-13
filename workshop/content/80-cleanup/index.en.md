---
title: 'Cleanup'
weight: 80
---

## Proven stages (Stages 0-2b)

```bash
# Tear down the Gateway KB target Lambda
cd applications/gateway-kb-target
# (no teardown script yet — delete manually via AWS console or CLI)

# Tear down the managed KB
cd applications/stage1-kb
bash teardown-kb.sh

# Tear down the AgentCore Runtime + Gateway
cd applications/stage0hello
agentcore destroy
```

## Stage 2 broker (if deployed)

The Stage 2 broker Lambda (`stage2-cred-broker`) can be deleted via the AWS console
or `aws lambda delete-function --function-name stage2-cred-broker`.

## Eventual packaged teardown

`bash infrastructure/scripts/teardown.sh` — not yet functional (see
`infrastructure/README.md`).
