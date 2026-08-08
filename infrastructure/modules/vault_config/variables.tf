variable "agentcore_issuer" {
  type        = string
  description = "AgentCore Identity issuer (iss claim) that Vault trusts."
}

variable "agentcore_jwks_url" {
  type        = string
  description = "AgentCore Identity JWKS endpoint URL. Vault fetches signing keys here to validate agent JWTs."
}

variable "agentcore_audiences" {
  type        = list(string)
  description = "Accepted JWT audiences (the agent workload audience[s])."
}

variable "rds_endpoint" {
  type        = string
  description = "RDS PostgreSQL endpoint (host:port)."
}

variable "rds_db_name" {
  type        = string
  description = "Database name."
}

variable "rds_master_username" {
  type        = string
  description = "RDS master username for the Vault DB secrets engine connection."
}

variable "rds_master_user_secret_arn" {
  type        = string
  description = "Secrets Manager ARN holding the RDS master password (never passed as a plain var)."
}

variable "bedrock_reader_role_arn" {
  type        = string
  description = "IAM role ARN that aws/sts/bedrock-reader assumes for scoped Bedrock KB access."
}
