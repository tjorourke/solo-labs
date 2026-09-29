import json
import os

from google.adk import Agent
from google.adk.models.lite_llm import LiteLlm

from .mcp_tools import get_mcp_tools

os.environ.setdefault("OTEL_SERVICE_NAME", "my-agents")

from google.adk.telemetry.setup import maybe_set_otel_providers
maybe_set_otel_providers()


def create_model():
    """The company gateway when MODEL_BASE_URL is set, otherwise straight to the provider.

    Through the gateway the model is addressed as openai/<name>, because the gateway reads
    identity from an Authorization: Bearer header and that is the shape LiteLLM sends it on.
    The Anthropic shape sends x-api-key, which the gateway does not read, so the request
    arrives with no subject and is refused. MODEL_API_KEY is the agent's own JWT, not a
    provider key: the gateway decides the model from the prompt and the subject.
    """
    model = os.environ.get("MODEL_NAME") or "claude-haiku-4-5"
    base = os.environ.get("MODEL_BASE_URL")
    if base:
        return LiteLlm(
            model="openai/" + model.split("/", 1)[-1],
            api_base=base,
            api_key=os.environ.get("MODEL_API_KEY") or "",
        )
    if not model.startswith("anthropic/"):
        model = "anthropic/" + model
    return LiteLlm(model=model, api_key=os.environ.get("ANTHROPIC_API_KEY") or None)


def instruction():
    return os.environ.get("SYSTEM_MESSAGE") or (
        "You are a helpful assistant. Use only the tools you have been given."
    )


def allowed_tools():
    """MCP filter matches the server's own names (list_issues)."""
    raw = os.environ.get("ALLOWED_TOOLS") or ""
    if not raw.strip():
        return None
    try:
        names = json.loads(raw)
    except json.JSONDecodeError:
        names = [t.strip() for t in raw.split(",") if t.strip()]
    out = []
    seen = set()
    for n in names:
        base = n.split(".", 1)[-1]
        if base.startswith("github_"):
            base = base[len("github_"):]
        for alias in (n, base):
            if alias and alias not in seen:
                seen.add(alias)
                out.append(alias)
    return out or None


# Two toolsets, same MCP: unprefixed list_issues and ADK's github_list_issues.
_filter = allowed_tools()
mcp_tools = (
    get_mcp_tools(global_filter=_filter, prefix=False)
    + get_mcp_tools(global_filter=_filter, prefix=True)
)
root_agent = Agent(
    model=create_model(),
    name="my_agents_agent",
    description=os.environ.get("AGENT_DESCRIPTION") or "AgentRegistry agent.",
    instruction=instruction(),
    tools=mcp_tools if mcp_tools else [],
)
