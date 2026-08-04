"""__NAME__ — an ADK SRE assistant.

Scaffolded with:

  arctl init agent __NAME__ --framework adk --language python \
      --model-provider anthropic --model-name claude-haiku-4-5

The scaffold's sample tools (roll_die, check_prime) are removed; the agent's only
tools come from the sre-tools MCP server, resolved at startup from the
MCP_SERVERS_CONFIG env var that AgentRegistry injects at deploy time.

The one thing worth noticing is that the toolsets are built with ADK's
require_confirmation hook wired to an environment variable. The developer never
names a tool as sensitive; the platform team decides that from outside and injects
it. When it fires, ADK pauses the tool and the approval appears in the kagent UI.

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
import json
import os

from google.adk import Agent
from google.adk.models.lite_llm import LiteLlm
from google.adk.tools.mcp_tool.mcp_toolset import (
    MCPToolset,
    StreamableHTTPConnectionParams,
)

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

    Both agents ship this identical code.
    """
    return LiteLlm(model="anthropic/claude-haiku-4-5")


def _gated_tools():
    """Tool names the PLATFORM has decided need human approval.

    Read from KAGENT_REQUIRE_APPROVAL, a comma-separated list. The developer never
    sets this and never names a tool; the platform injects it at admission from the
    risk register. Absent or empty means nothing needs approval.
    """
    raw = os.environ.get("KAGENT_REQUIRE_APPROVAL", "")
    return {t.strip() for t in raw.split(",") if t.strip()}


def build_mcp_tools():
    """Build the agent's MCP toolsets from MCP_SERVERS_CONFIG.

    Same input as arctl's generated mcp_tools.py — a JSON list of {name, type, url}
    injected by AgentRegistry at deploy time — but built here so ADK's native
    require_confirmation hook can be wired up.

    require_confirmation makes ADK pause before running a tool and emit the
    confirmation request that kagent renders as an approval card in its UI. That is
    the same surface a declarative agent's requireApproval produces, so a BYO agent
    gets kagent's own approval flow with nothing sitting in front of it.

    Why TWO toolsets per server rather than one with a predicate:

    require_confirmation is a per-toolset setting, and when ADK invokes the callable
    form it passes the TOOL'S OWN ARGUMENTS plus tool_context — not the tool name
    (google/adk/tools/mcp_tool/mcp_tool.py, run_async). So a single callable cannot
    tell which tool it is being asked about. Splitting the server into a gated
    toolset and an ungated one, using tool_filter to decide membership, puts the
    tool name where it is actually available.
    """
    gated = _gated_tools()

    raw = os.environ.get("MCP_SERVERS_CONFIG", "")
    try:
        servers = json.loads(raw) if raw else []
    except ValueError:
        servers = []

    timeout = float(os.environ.get("MCP_CONNECT_TIMEOUT", "60"))
    terminate = os.environ.get("MCP_TERMINATE_ON_CLOSE", "true").lower() != "false"

    def conn(url):
        return StreamableHTTPConnectionParams(
            url=url, timeout=timeout, terminate_on_close=terminate
        )

    toolsets = []
    for srv in servers:
        url = srv.get("url") or ""
        if not url:
            continue

        if not gated:
            # Nothing is gated for this agent: one plain toolset, no confirmation.
            toolsets.append(MCPToolset(connection_params=conn(url)))
            continue

        # Everything the platform did NOT name — runs straight through.
        toolsets.append(
            MCPToolset(
                connection_params=conn(url),
                tool_filter=lambda tool, ctx=None: tool.name not in gated,
            )
        )
        # The tools the platform DID name — ADK pauses and kagent asks a human.
        toolsets.append(
            MCPToolset(
                connection_params=conn(url),
                tool_filter=lambda tool, ctx=None: tool.name in gated,
                require_confirmation=True,
            )
        )
    return toolsets


mcp_tools = build_mcp_tools()
root_agent = Agent(
    model=create_model(),
    name="__NAME___agent",
    description="SRE assistant: triage and remediate unhealthy workloads via the sre-tools MCP server.",
    instruction=build_instruction(INSTRUCTION),
    tools=mcp_tools if mcp_tools else [],
)
