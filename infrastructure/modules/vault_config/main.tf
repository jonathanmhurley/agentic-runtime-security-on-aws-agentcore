################################################################################
# vault_config Module — Main (AgentCore edition)
#
# Provisions Vault Enterprise configuration for the workshop:
#   - Audit device: file -> stdout, json (single-plane audit trail)
#   - OAuth resource server profile: validates AgentCore-issued JWTs directly
#     via X-Vault-Token against the workshop JWKS endpoint.
#   - AWS secrets engine: aws/sts/bedrock-reader (scoped Bedrock STS)
#   - Agent Registry: uc1-agent identity entity + registration
#   - Policy: uc1 (read-only access to aws/sts/bedrock-reader)
#
# DB secrets engine (uc1-readonly, uc2-personal-readonly) is commented out —
# no RDS deployed for UC1. Add back when UC2 introduces database credentials.
################################################################################

terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
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
################################################################################

resource "vault_audit" "stdout" {
  type = "file"
  options = {
    file_path = "stdout"
    format    = "json"
  }
}

################################################################################
# OAuth resource server — validates the workshop JWT directly via X-Vault-Token
#
# The JWT is signed with our local RS256 keypair; Vault fetches the public key
# from the GitHub-hosted JWKS endpoint. No Vault login round-trip.
################################################################################

resource "vault_generic_endpoint" "activate_oauth_rs" {
  path                 = "sys/activation-flags/oauth-resource-server/activate"
  ignore_absent_fields = true
  disable_read         = true
  disable_delete       = true
  data_json = "{}"
}

resource "vault_generic_endpoint" "oauth_profile" {
  depends_on           = [vault_generic_endpoint.activate_oauth_rs]
  path                 = "sys/config/oauth-resource-server/agentcore"
  ignore_absent_fields = true
  disable_delete       = true
  data_json = jsonencode({
    issuer_id                      = var.agentcore_issuer
    use_jwks                       = true
    jwks_uri                       = var.agentcore_jwks_url
    audiences                      = var.agentcore_audiences
    supported_algorithms           = ["RS256"]
    user_claim                     = "sub"
    optional_authorization_details = true
  })
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
# Vault policy — uc1 (bedrock STS only; DB path added when RDS exists)
################################################################################

resource "vault_policy" "uc1" {
  name   = "uc1"
  policy = <<-EOT
    path "aws/sts/bedrock-reader" { capabilities = ["read"] }
  EOT
}

################################################################################
# Identity entity + Agent Registry for uc1-agent
#
# The Agent Registry requires an existing identity entity. We create one for
# the UC1 agent, attach the uc1 policy, then register it in the Agent Registry.
################################################################################

resource "vault_identity_entity" "uc1_agent" {
  name     = "uc1-agent"
  policies = [vault_policy.uc1.name]
  metadata = {
    purpose = "Workshop UC1 read-only agent (AgentCore Runtime)"
  }
}

resource "vault_generic_endpoint" "agent_registry_uc1" {
  depends_on           = [vault_identity_entity.uc1_agent, vault_generic_endpoint.oauth_profile]
  path                 = "agent-registry/register"
  ignore_absent_fields = true
  disable_read         = true
  disable_delete       = true
  data_json = jsonencode({
    display_name                   = "uc1-agent"
    entity_id                      = vault_identity_entity.uc1_agent.id
    optional_authorization_details = true
    ceiling_policies               = ["uc1"]
  })
}

################################################################################
# DB secrets engine — COMMENTED OUT (no RDS deployed for UC1)
# Uncomment when UC2 introduces database credentials.
################################################################################

# resource "vault_mount" "database" {
#   path = "database"
#   type = "database"
# }
#
# resource "vault_database_secret_backend_connection" "pg" {
#   backend           = vault_mount.database.path
#   name              = "workshop-pg"
#   allowed_roles     = ["uc1-readonly"]
#   verify_connection = false
#   postgresql {
#     connection_url = "postgresql://{{username}}:{{password}}@${var.rds_endpoint}/${var.rds_db_name}?sslmode=require"
#     username       = var.rds_master_username
#     password       = var.rds_master_password
#   }
# }
#
# resource "vault_database_secret_backend_role" "uc1_readonly" {
#   backend     = vault_mount.database.path
#   name        = "uc1-readonly"
#   db_name     = vault_database_secret_backend_connection.pg.name
#   default_ttl = 900
#   max_ttl     = 1800
#   creation_statements = [
#     "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
#     "GRANT USAGE ON SCHEMA banking TO \"{{name}}\";",
#     "GRANT SELECT ON ALL TABLES IN SCHEMA banking TO \"{{name}}\";",
#   ]
# }
