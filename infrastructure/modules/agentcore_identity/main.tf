################################################################################
# agentcore_identity Module (NEW — replaces IVIA as issuer + Vault k8s auth)
#
# Provisions AgentCore Identity: the workload identity for each agent (ARN) and
# the JWT issuer whose JWKS endpoint Vault trusts. For UC1 the agent presents a
# workload-identity JWT (no user context yet); UC2/UC3 add user-context claims
# via the OBO credential provider (see agentcore_obo module).
#
# NOTE: AgentCore control-plane resources are provisioned via the AWS provider
# where Terraform support exists, and via a null_resource + AWS CLI
# (aws bedrock-agentcore-control ...) bootstrap where it does not yet. All CLI
# calls use --profile agentic. Pin the bedrock-agentcore surface (DESIGN sec 7).
################################################################################

terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

# Workload identity for the UC1 agent. TODO: replace with the native AgentCore
# Terraform resource once available; bootstrap via CLI in the interim.
resource "null_resource" "uc1_workload_identity" {
  triggers = {
    workload_name = var.uc1_workload_name
    region        = var.region
  }
  # provisioner "local-exec" {
  #   command = "aws bedrock-agentcore-control create-workload-identity --profile agentic --region ${var.region} --name ${var.uc1_workload_name}"
  # }
}
