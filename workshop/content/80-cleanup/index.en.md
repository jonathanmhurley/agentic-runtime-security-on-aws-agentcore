---
title: 'Cleanup'
weight: 80
---

## Tear down in reverse order

### Vault Enterprise

```bash
# Terminate the Vault EC2 instance
aws ec2 terminate-instances --instance-ids <VAULT_INSTANCE_ID> --region us-east-1

# Delete the security group (after instance terminates)
aws ec2 delete-security-group --group-id <SG_ID> --region us-east-1
```

### Gateway KB target Lambda

```bash
aws lambda delete-function --function-name gateway-kb-target --region us-east-1
```

### Managed Knowledge Base

```bash
cd applications/stage1-kb
bash teardown-kb.sh
```

### AgentCore Runtime + Gateway

```bash
cd applications/stage0hello
agentcore destroy
```

### Stage 2 broker (if deployed)

```bash
aws lambda delete-function --function-name stage2-cred-broker --region us-east-1
```

### IAM cleanup

Remove the inline policies added during the workshop:
```bash
aws iam delete-user-policy --user-name hurleyjm --policy-name assume-vended-role
aws iam delete-role-policy --role-name Stage2VendedKBReadRole --policy-name kb-read
```
