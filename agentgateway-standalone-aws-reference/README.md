# agentgateway standalone on AWS, Part 3: full configuration reference

**Standalone AWS series:** [Part 1: OSS setup and high availability](../agentgateway-standalone-aws-ha/) · [Part 2: Enterprise setup and features](../agentgateway-standalone-aws-enterprise/) · **Part 3: full configuration reference**

The walkthrough is at https://mastertheagent.com/solo/agentgateway-standalone-aws-reference/

This part has no scripts or Terraform. It is one annotated agentgateway config file that
covers gateways, routes, policies, LLM models and providers, MCP and Vault, with the
comments explaining each block. It was run against a local agentgateway v1.7.0 binary.

| File | What it is |
| --- | --- |
| `config/agentgateway-config.yaml` | The full standalone config |
| `config/vsr-config.yaml` | vLLM Semantic Router's own routing config, used by the external classifier section |

Run it on a laptop:

```bash
export OPENAI_API_KEY=...
export ANTHROPIC_API_KEY=...
export SESSION_KEY=$(openssl rand -hex 32)
agentgateway -f config/agentgateway-config.yaml
```

The comments in the file say which sections were tested live and which (vSR, the IdP,
Vault and the external SaaS guardrail) depend on something outside the file.
