"""vault_client.py — Vault client for the UC1 non-personalized read-only agent.

AgentCore edition — single-phase auth (workload identity only, no user context):

  The agent obtains its AgentCore workload-identity JWT from AgentCore Identity
  and presents it DIRECTLY as the Vault token via the X-Vault-Token header.
  Vault's OAuth resource server (profile "agentcore") validates the JWT against
  the AgentCore JWKS endpoint and authorizes per the "uc1" policy — there is NO
  Vault login round-trip and NO intermediate Vault token. This replaces the
  EKS Kubernetes auth method from the reference architecture.

  Used for:
    - get_readonly_credentials(): uc1-readonly DB creds (SELECT-only, TTL 15m)
    - get_bedrock_credentials():  aws/sts/bedrock-reader STS creds for the KB

This establishes OBJ-1 (verifiable agent identity) and OBJ-2 (no standing
privileges — every credential is JIT and dies with its lease). No user identity
is involved in UC1; that arrives in UC2 via AgentCore OBO.
"""

import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
import hvac
from botocore.credentials import RefreshableCredentials
from botocore.session import get_session as _get_botocore_session

logger = logging.getLogger(__name__)


class UC1VaultClient:
    """Vault client for the UC1 read-only agent (AgentCore workload identity).

    Lifecycle:
      1. Construct with vault_addr.
      2. set_workload_jwt(jwt) — supply the AgentCore workload-identity JWT.
      3. get_readonly_credentials() — uc1-readonly DB creds for KB-adjacent reads.
      4. get_bedrock_credentials() — boto3.Session backed by RefreshableCredentials
         over aws/sts/bedrock-reader (botocore re-issues the lease transparently).
    """

    def __init__(self, vault_addr: str) -> None:
        self._addr = vault_addr
        self._jwt = None

    def set_workload_jwt(self, jwt: str) -> None:
        """Store the AgentCore workload-identity JWT presented as the Vault token."""
        self._jwt = jwt
        logger.info("uc1_workload_jwt_set", extra={"auth_method": "oauth_resource_server_x_vault_token"})

    def _client(self) -> "hvac.Client":
        """Return an hvac client that presents the AgentCore JWT as X-Vault-Token.

        The JWT IS the Vault credential (OAuth resource server profile "agentcore").
        Never sent as an Authorization header (that silently resolves to no identity).
        """
        if not self._jwt:
            raise RuntimeError("UC1 workload JWT not set — call set_workload_jwt() first")
        return hvac.Client(url=self._addr, token=self._jwt)

    def get_readonly_credentials(self) -> dict:
        """Fetch uc1-readonly DB credentials (SELECT-only, JIT).

        Vault validates the AgentCore JWT via JWKS, checks the Agent Registry
        (uc1-agent registered + approved), and issues short-lived DB creds.

        Returns:
            Dict with keys: username, password, host, port, dbname
        """
        vault_db_path = os.getenv("VAULT_DB_READONLY_PATH", "database/creds/uc1-readonly")
        response = self._client().read(vault_db_path)
        data = response["data"]
        logger.info(
            "uc1_db_creds_issued",
            extra={
                "vault_db_path": vault_db_path,
                "lease_id": response.get("lease_id", "n/a"),
                "lease_duration": response.get("lease_duration", "unknown"),
                "username": data.get("username", "n/a"),
            },
        )
        return {
            "username": data["username"],
            "password": data["password"],
            "host": os.getenv("DB_HOST", "localhost"),
            "port": int(os.getenv("DB_PORT", "5432")),
            "dbname": os.getenv("DB_NAME", "workshop"),
        }

    def get_bedrock_credentials(self) -> boto3.Session:
        """boto3.Session with auto-refreshing Bedrock STS creds (OBJ-2).

        Backed by botocore RefreshableCredentials over Vault's
        aws/sts/bedrock-reader role — leases are re-minted transparently as they
        approach expiry, so the agent never hits ExpiredTokenException and holds
        no standing AWS identity.
        """
        region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
        if not region:
            raise RuntimeError("AWS_REGION (or AWS_DEFAULT_REGION) must be set")
        vault_path = "aws/sts/bedrock-reader"

        def _refresh() -> dict:
            response = self._client().read(vault_path)
            data = response["data"]
            lease_seconds = int(response.get("lease_duration") or 900)
            expiry = datetime.now(timezone.utc) + timedelta(seconds=lease_seconds)
            logger.info(
                "uc1_bedrock_sts_credentials_issued",
                extra={"lease_id": response.get("lease_id", "n/a"), "lease_seconds": lease_seconds, "region": region},
            )
            return {
                "access_key": data["access_key"],
                "secret_key": data["secret_key"],
                "token": data["security_token"],
                "expiry_time": expiry.isoformat(),
            }

        creds = RefreshableCredentials.create_from_metadata(
            metadata=_refresh(), refresh_using=_refresh, method="vault-aws-sts",
        )
        botocore_session = _get_botocore_session()
        botocore_session._credentials = creds
        botocore_session.set_config_variable("region", region)
        return boto3.Session(botocore_session=botocore_session, region_name=region)
