variable "region" { type = string }
variable "uc1_workload_identity" {
  type        = string
  description = "AgentCore workload identity (ARN/name) for the UC1 agent."
}
variable "vault_addr" {
  type        = string
  description = "Vault address the agent authenticates against (X-Vault-Token with the AgentCore JWT)."
}
variable "bedrock_model_id" {
  type        = string
  description = "Bedrock model id for agent reasoning (Nova Pro via CRIS: us.amazon.nova-pro-v1:0)."
  default     = "us.amazon.nova-pro-v1:0"
}
