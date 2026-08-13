################################################################################
# STUB — not functional. See infrastructure/README.md.
# These null_resource placeholders document the intent; actual deployment uses
# the AgentCore CLI (agentcore create/deploy). Do NOT terraform apply.
################################################################################

variable "region" { type = string }
variable "uc1_workload_name" {
  type        = string
  description = "AgentCore workload identity name for the UC1 agent."
  default     = "workshop-uc1"
}
