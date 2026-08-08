# Emitted for vault_config to consume (issuer + JWKS + audience).
output "issuer" {
  value       = var.agentcore_issuer_override
  description = "AgentCore Identity issuer (iss). TODO: source from the created resource once native TF exists."
}
output "jwks_url" {
  value       = var.agentcore_jwks_override
  description = "AgentCore Identity JWKS endpoint. TODO: source from the created resource."
}
variable "agentcore_issuer_override" { type = string, default = "" }
variable "agentcore_jwks_override"   { type = string, default = "" }
