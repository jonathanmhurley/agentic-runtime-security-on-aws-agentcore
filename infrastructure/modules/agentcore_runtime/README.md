> ⚠️ **STUB** — this module is a design reference, not functional Terraform. See `infrastructure/README.md`.

# Module: agentcore_runtime

**NEW.** Deploys the Strands agents onto Amazon Bedrock AgentCore Runtime
(managed, serverless). Replaces the EKS agent pods. Agent source lives under
`applications/ucN-agent/`.

**Container artifact:** `CreateAgentRuntime` takes an **ECR container image** as
its `agentRuntimeArtifact` plus an execution `roleArn`. You do NOT hand-write a
Dockerfile or a Kubernetes manifest — the AgentCore starter toolkit
(`bedrock_agentcore_starter_toolkit`) generates the Dockerfile, builds the image
via CodeBuild, and pushes it to an ECR repo it creates during `launch`. So a
container image is still in the loop; what goes away is the EKS pod/manifest
machinery, not the image itself.

**UC1:** binds the `uc1-agent` runtime to its AgentCore workload identity
(auto-created with the runtime; ARN returned as `workloadIdentityDetails.
workloadIdentityArn`) and configures the Vault address + Bedrock model id
(`us.amazon.nova-pro-v1:0`). Inbound auth uses a `customJWTAuthorizer`
(`discoveryUrl` + `allowedClients`) set in `authorizerConfiguration`.

**Note:** provisioned via the starter toolkit / `aws bedrock-agentcore-control
create-agent-runtime --profile agentic` where native Terraform support does not
yet exist (null_resource placeholders mark those spots).

**Status:** new (replaces modules/eks + agent pod deployments).
