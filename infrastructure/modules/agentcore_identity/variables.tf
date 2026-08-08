variable "region" { type = string }
variable "uc1_workload_name" {
  type        = string
  description = "AgentCore workload identity name for the UC1 agent."
  default     = "workshop-uc1"
}
