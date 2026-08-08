# Module: ecr

Container image repository for the AgentCore Runtime agent image(s).

**Required, not conditional.** `CreateAgentRuntime` takes an ECR container image
as its artifact. In the normal flow the AgentCore starter toolkit auto-creates
the ECR repo during `launch` (via CodeBuild), so this module may be a thin
wrapper or unused when the toolkit owns repo creation. Keep it for the case
where we pre-provision the repo with Terraform (stable naming, lifecycle
policies, cross-account access) instead of letting the toolkit create it.

**Status:** stays (ECR is part of the AgentCore packaging path; ownership of repo
creation — toolkit vs. this module — decided during build design).
