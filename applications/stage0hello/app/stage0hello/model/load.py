from strands.models.bedrock import BedrockModel


def load_model() -> BedrockModel:
    """Get Bedrock model client using IAM credentials.

    Nova Pro via the cross-region inference profile (CRIS) id. The bare
    `amazon.nova-pro-v1:0` id is rejected for on-demand throughput, so the
    workshop standard is the `us.` CRIS-prefixed id.
    """
    return BedrockModel(model_id="us.amazon.nova-pro-v1:0")
