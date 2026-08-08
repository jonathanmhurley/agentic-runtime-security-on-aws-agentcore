output "oauth_profile_name" {
  value       = vault_oauth_resource_server_config_profile.agentcore.profile_name
  description = "Vault OAuth resource server profile name for AgentCore JWTs."
}

output "uc1_db_role" {
  value       = vault_database_secret_backend_role.uc1_readonly.name
  description = "Vault DB role for UC1 read-only JIT credentials."
}
