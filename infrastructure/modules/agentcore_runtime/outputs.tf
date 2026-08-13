################################################################################
# STUB — not functional. See infrastructure/README.md.
# These null_resource placeholders document the intent; actual deployment uses
# the AgentCore CLI (agentcore create/deploy). Do NOT terraform apply.
################################################################################

output "uc1_runtime_id" {
  value       = null_resource.uc1_agent_runtime.id
  description = "Placeholder id for the UC1 AgentCore Runtime agent (until native TF resource exists)."
}
