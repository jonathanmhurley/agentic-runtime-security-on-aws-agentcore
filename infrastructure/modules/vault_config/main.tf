################################################################################
# vault_config Module — Main (AgentCore edition, UC1 slice)
#
# Bridges the self-hosted Vault Enterprise deployment to the AgentCore-hosted
# agents. UC1 slice provisions:
#   - Audit device: file -> stdout, json (single-plane audit trail)
#   - OAuth resource server profile (CONF-02): validates AgentCore Identity
#     JWTs DIRECTLY via X-Vault-Token against the AgentCore JWKS endpoint.
#     No Vault login round-trip. Replaces the retired Kubernetes auth method.
#   - PostgreSQL secrets engine + uc1-readonly role (SELECT-only)
#   - AWS secrets engine: aws/sts/bedrock-reader (scoped Bedrock STS for the KB)
#   - Agent Registry (beta): uc1 agent registration (Enterprise; version-pinned)
#
# UC2/UC3 slices (per-user OBO, refund-writer) are added in their own files.
################################################################################

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
      # 5.10.1 is the first release exposing vault_oauth_resource_server_config_profile
      # + vault_agent_registration. Pin the exact patch floor (carried forward from
      # the EKS repo's 09-DISCOVERY PROVIDER_MIN). See docs/DESIGN.md section 7.
      version = ">= 5.10.1, < 6.0.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

################################################################################
# Vault audit device — single hash-chained stream (JSON)
# The AgentCore-issued JWT carries resolved user identity end-to-end, so this
# ONE stream answers user + agent + authorization + lease (see DESIGN section 3.4).
################################################################################

resource "vault_audit" "stdout" {
  type = "file"
  options = {
    file_path = "stdout"
    format    = "json"
  }
}

################################################################################
# OAuth resource server — CONF-02 (retargeted to AgentCore Identity JWKS)
#
# The AgentCore Identity JWT authorizes a Vault request DIRECTLY via the
# X-Vault-Token header against this resource-server profile. No jwt_login
# round-trip, no synthetic Vault token. This replaces the EKS Kubernetes auth
# method entirely.
#
#   issuer_id  <- AgentCore Identity issuer
#   jwks_uri   <- AgentCore Identity JWKS endpoint (var.agentcore_jwks_url)
#   audiences  <- the agent workload audience(s)
#   user_claim <- "sub" (the agent workload identity subject for UC1)
################################################################################

resource "vault_activation_flags" "oauth_resource_server" {
  feature = "oauth-resource-server"
}

resource "vault_oauth_resource_server_config_profile" "agentcore" {
  profile_name         = "agentcore"
  issuer_id            = var.agentcore_issuer
  use_jwks             = true
  jwks_uri             = var.agentcore_jwks_url
  audiences            = var.agentcore_audiences
  supported_algorithms = ["RS256"]
  user_claim           = "sub"

  depends_on = [vault_activation_flags.oauth_resource_server]
}

################################################################################
# PostgreSQL secrets engine + uc1-readonly role (SELECT-only, JIT, TTL-bound)
################################################################################

resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "pg" {
  backend           = vault_mount.database.path
  name              = "workshop-pg"
  allowed_roles     = ["uc1-readonly"]
  verify_connection = false

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${var.rds_endpoint}/${var.rds_db_name}?sslmode=require"
    username       = var.rds_master_username
    password       = local.rds_master_password
  }
}

resource "vault_database_secret_backend_role" "uc1_readonly" {
  backend     = vault_mount.database.path
  name        = "uc1-readonly"
  db_name     = vault_database_secret_backend_connection.pg.name
  default_ttl = 900  # 15m — JIT, no standing creds (OBJ-2)
  max_ttl     = 1800
  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT USAGE ON SCHEMA banking TO \"{{name}}\";",
    "GRANT SELECT ON ALL TABLES IN SCHEMA banking TO \"{{name}}\";",
  ]
  revocation_statements = [
    "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA banking FROM \"{{name}}\";",
    "REVOKE USAGE ON SCHEMA banking FROM \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";",
  ]
}

################################################################################
# AWS secrets engine — aws/sts/bedrock-reader (scoped Bedrock STS for the KB)
################################################################################

resource "vault_aws_secret_backend" "aws" {
  path = "aws"
}

resource "vault_aws_secret_backend_role" "bedrock_reader" {
  backend         = vault_aws_secret_backend.aws.path
  name            = "bedrock-reader"
  credential_type = "assumed_role"
  role_arns       = [var.bedrock_reader_role_arn]
  default_sts_ttl = 900
  max_sts_ttl     = 1800
}

################################################################################
# Vault policy — uc1 (read-only DB creds + bedrock STS)
################################################################################

resource "vault_policy" "uc1" {
  name   = "uc1"
  policy = <<-EOT
    path "database/creds/uc1-readonly" { capabilities = ["read"] }
    path "aws/sts/bedrock-reader"      { capabilities = ["read"] }
  EOT
}

################################################################################
# Agent Registry (beta, Enterprise) — UC1 agent registration
# BETA: pinned via the provider floor above. Isolated so a beta API shift has a
# one-resource blast radius (DESIGN section 7).
################################################################################

resource "vault_agent_registration" "uc1" {
  # Registers the UC1 agent workload identity as a Vault identity entity with
  # approved scopes. Unregistered agents are blocked.
  name                          = "uc1-agent"
  profile_name                  = vault_oauth_resource_server_config_profile.agentcore.profile_name
  policies                      = [vault_policy.uc1.name]
  optional_authorization_details = true # UC1: RAR optional (UC3 will set false)
}
