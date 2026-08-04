"""__NAME__ — an ADK SRE assistant.

Scaffolded with:

  arctl init agent __NAME__ --framework adk --language python \
      --model-provider anthropic --model-name claude-haiku-4-5

The scaffold's sample tools (roll_die, check_prime) are removed; the agent's only
tools come from the sre-tools MCP server, resolved at startup from the
MCP_SERVERS_CONFIG env var that AgentRegistry injects at deploy time.

DO NOT EDIT THE COPIES. This file is the single source for BOTH agents:
scripts/06-agents.sh renders it into artifacts/sretriage/sretriage/agent.py and
artifacts/sreremediate/sreremediate/agent.py, substituting only __NAME__.

That the two agents are byte-identical apart from their name is load-bearing, not
tidiness. It means anything that later differs between them was done TO them from
the outside, and cannot be explained by the code. If you edit one copy by hand
the lab stops proving its point.

Note what is NOT here: no approval logic, no confirmation prompt, no notion that
some tools are more dangerous than others, and no mention of a gateway. A
developer writing this has not been asked to think about human-in-the-loop, and
is not trusted to implement it. Every control in this lab is applied to the agent
after this code is finished.
"""
import os

from google.adk import Agent
from google.adk.models.lite_llm import LiteLlm

from .mcp_tools import get_mcp_tools
from .prompts_loader import build_instruction

# Set the OTel service name before the providers are initialised, so traces for
# this agent are attributable per agent.
os.environ.setdefault("OTEL_SERVICE_NAME", "__NAME__")

from google.adk.telemetry.setup import maybe_set_otel_providers  # noqa: E402

maybe_set_otel_providers()


INSTRUCTION = """
You are an SRE assistant for a small Kubernetes estate. You have tools from the
sre-tools MCP server to inspect and repair workloads.

Work in this order:

1. Look before you touch. Use list_pods to find unhealthy pods, get_pod_logs to
   read why they are failing, and describe_deployment to check replica counts and
   images.
2. Say what you found. State the diagnosis in one or two sentences, citing the
   specific evidence from the logs or the restart counts.
3. Then act, if acting is warranted. restart_deployment and scale_deployment
   change the running system. Before calling either, say in one sentence what you
   are about to change and why it follows from the diagnosis.
4. Report what changed. After a tool returns, summarise the new state.

Some tool calls take a while to come back. That is normal; wait for the result
rather than retrying or assuming failure.

If a tool call comes back refused or denied, report the reason you were given,
verbatim, and stop. Do not retry it, do not work around it, and do not try a
different tool to achieve the same effect.
"""


def create_model():
    """Use an Anthropic model via LiteLLM.

    The key comes from ANTHROPIC_API_KEY in the pod env, which Kyverno injects as
    a secretKeyRef at admission — it is never written into this project, the
    registry record, or the Agent CR spec.

    ANTHROPIC_API_BASE is read explicitly and passed as api_base rather than left
    to LiteLLM's own env discovery. LiteLLM does honour ANTHROPIC_API_BASE, but
    only on its text-completion and /models paths; the /v1/messages chat path that
    ADK uses resolves api_base from the call, not from the environment. Relying on
    the env var alone would silently send traffic straight to api.anthropic.com
    and the platform's redirect would appear to work while doing nothing.

    Both agents ship this identical code. Neither sets the variable. Whether it is
    present in the pod is the platform team's decision, not the developer's.
    """
    kwargs = {"model": "anthropic/claude-haiku-4-5"}
    api_base = os.environ.get("ANTHROPIC_API_BASE")
    if api_base:
        kwargs["api_base"] = api_base
    return LiteLlm(**kwargs)


mcp_tools = get_mcp_tools()
root_agent = Agent(
    model=create_model(),
    name="__NAME___agent",
    description="SRE assistant: triage and remediate unhealthy workloads via the sre-tools MCP server.",
    instruction=build_instruction(INSTRUCTION),
    tools=mcp_tools if mcp_tools else [],
)
