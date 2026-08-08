################################################################################
# agentcore_runtime Module (NEW — replaces EKS agent pods)
#
# Deploys the Strands agents onto Amazon Bedrock AgentCore Runtime (managed,
# serverless). Agent source lives under applications/ucN-agent/, packaged for
# AgentCore (no Dockerfile -> ECR -> pod). Each runtime agent is bound to its
# AgentCore workload identity (from agentcore_identity) and configured with the
# Vault address + OAuth resource-server profile it authenticates against.
#
# Provisioned via AWS provider where available, CLI bootstrap otherwise
# (aws bedrock-agentcore-control create-agent-runtime ..., --profile agentic).
################################################################################

terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

resource "null_resource" "uc1_agent_runtime" {
  triggers = {
    workload_identity = var.uc1_workload_identity
    vault_addr        = var.vault_addr
    bedrock_model_id  = var.bedrock_model_id
    region            = var.region
  }
  # provisioner "local-exec" {
  #   command = "aws bedrock-agentcore-control create-agent-runtime --profile agentic --region ${var.region} ..."
  # }
}
