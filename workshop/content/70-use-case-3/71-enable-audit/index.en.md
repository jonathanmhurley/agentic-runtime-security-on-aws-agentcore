---
title: 'Enable Vault file audit'
weight: 71
---

## Check current audit devices

Vault dev-mode may ship with an audit device writing to stdout (useful for
debugging, useless for inspection). Check what's configured:

```bash
export VAULT_ADDR=http://<VAULT_IP>:8200
export VAULT_TOKEN=workshop-root-token

vault audit list -detailed
```

If the output shows `file_path=stdout`, the entries are vanishing into the process
log. Switch to a file.

## Enable file-based audit

Disable the existing stdout device (if present) and enable a file device:

```bash
vault audit disable file
vault audit enable file file_path=/var/log/vault-audit.log
```

Verify:

```bash
vault audit list -detailed
```

Expected output:

```text
Path     Type    Description    Replication    Options
----     ----    -----------    -----------    -------
file/    file    n/a            replicated     file_path=/var/log/vault-audit.log format=json
```

## What Vault logs

Every authenticated request and its response is written as a JSON line. Each entry
includes:

- `type`: `request` or `response`
- `time`: ISO 8601 timestamp
- `auth.display_name`: the identity that authenticated (e.g. `jwt-alice@example.com`)
- `auth.policies`: the policies attached to the token
- `request.path`: the API path called
- `request.id`: a UUID correlating the request with its response

Failed requests (403, invalid token, etc.) are also logged with full attribution.
Vault never silently drops an operation.

## Hash chaining

Each audit entry includes a `request.id` and a hash of the previous entry. This
makes the log tamper-evident: removing or altering a line breaks the chain. For
the workshop we won't verify hashes, but the property matters in production where
the log ships to S3 + CloudWatch for immutable storage.
