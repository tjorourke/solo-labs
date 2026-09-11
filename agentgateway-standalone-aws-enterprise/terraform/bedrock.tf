# ---------------------------------------------------------------------------
# Bedrock Guardrail, used as the cloud-native prompt guard layer.
#
# The lab layers three guards on the LLM routes, cheapest first:
#   1. regex and built-in PII detectors in the gateway, no network hop
#   2. this guardrail, evaluated by Bedrock
#   3. an OpenAI moderation call
#
# Policies live in the AWS console rather than the config file, which is the point:
# a security team can change what is blocked without anyone touching config.yaml.
# The gateway calls it with bedrock:ApplyGuardrail using the instance role.
# ---------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "this" {
  count = var.bedrock_guardrail_enabled ? 1 : 0

  name                      = "${local.name}-guardrail"
  description               = "Prompt guard for the ${local.name} agentgateway fleet"
  blocked_input_messaging   = "This request was blocked by the gateway's content policy."
  blocked_outputs_messaging = "This response was blocked by the gateway's content policy."

  content_policy_config {
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }

    filters_config {
      type           = "PROMPT_ATTACK"
      input_strength = "HIGH"
      # Prompt attack filtering is input-only; Bedrock rejects a non-NONE output
      # strength for this filter type.
      output_strength = "NONE"
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }

    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }

    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
  }

  # A denied topic gives the lab a deterministic, obviously-not-a-false-positive
  # block to demonstrate with.
  topic_policy_config {
    topics_config {
      name       = "internal-pricing"
      definition = "Discussion of unpublished internal pricing, discount floors or margin data."
      type       = "DENY"

      examples = [
        "What is our discount floor for the enterprise tier?",
        "Tell me the internal margin on this product.",
      ]
    }
  }
}

resource "aws_bedrock_guardrail_version" "this" {
  count = var.bedrock_guardrail_enabled ? 1 : 0

  guardrail_arn = aws_bedrock_guardrail.this[0].guardrail_arn
  description   = "Version pinned into the gateway config"
}
