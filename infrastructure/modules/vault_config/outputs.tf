output "uc1_entity_id" {
  value       = vault_identity_entity.uc1_agent.id
  description = "Vault identity entity ID for the uc1-agent (used in Agent Registry)."
}

output "aws_backend_path" {
  value       = vault_aws_secret_backend.aws.path
  description = "AWS secrets engine mount path."
}
