variable "agentcore_issuer" {
  type        = string
  description = "The issuer (iss claim) in the workshop JWT that Vault trusts."
}

variable "agentcore_jwks_url" {
  type        = string
  description = "JWKS endpoint URL. Vault fetches signing keys here to validate the workshop JWT."
}

variable "agentcore_audiences" {
  type        = list(string)
  description = "Accepted JWT audiences (the aud claim value[s])."
}

variable "bedrock_reader_role_arn" {
  type        = string
  description = "IAM role ARN that aws/sts/bedrock-reader assumes for scoped Bedrock KB access."
}

# --- DB variables (unused while DB resources are commented out) ---
# Uncomment when UC2 introduces database credentials.

# variable "rds_endpoint" {
#   type        = string
#   description = "RDS PostgreSQL endpoint (host:port)."
# }
#
# variable "rds_db_name" {
#   type        = string
#   description = "Database name."
# }
#
# variable "rds_master_username" {
#   type        = string
#   description = "RDS master username."
# }
#
# variable "rds_master_user_secret_arn" {
#   type        = string
#   description = "Secrets Manager ARN holding the RDS master password."
# }
