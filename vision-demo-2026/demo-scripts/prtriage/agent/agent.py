import os
from datetime import datetime, timezone

from google.adk import Agent

from google.adk.models.lite_llm import LiteLlm

from .mcp_tools import get_mcp_tools
from .prompts_loader import build_instruction

# Initialize OpenTelemetry
# Set service name from environment variable for OpenTelemetry
os.environ.setdefault('OTEL_SERVICE_NAME', 'prtriage')

from google.adk.telemetry.setup import maybe_set_otel_providers
maybe_set_otel_providers()


def today() -> str:
    """Return today's date as YYYY-MM-DD (UTC).

    The only local tool this agent has. It exists because the gateway's code-mode
    sandbox deliberately has no clock: `Date` is not defined in there, so a program
    cannot work out how old a pull request is on its own. The agent reads the date
    here and passes it into the program it writes.
    """
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def create_model():
    """Use an Anthropic model via LiteLLM."""
    return LiteLlm(model="anthropic/claude-haiku-4-5")


# Everything this agent can do to GitHub arrives through the approved MCP server
# in the catalogue, which resolves to an agentgateway route. There are no GitHub
# tools in this file, and no GitHub credential either.
mcp_tools = get_mcp_tools()
root_agent = Agent(
    model=create_model(),
    name="prtriage_agent",
    description="Reports which open pull requests are ready to merge and which are blocked.",
    instruction=build_instruction("""
    You report on the state of open pull requests in a GitHub repository.
    Follow the release-report skill in your instructions for how to gather the
    data and how to format the answer.
    """),
    tools=[
        today,
    ] + (mcp_tools if mcp_tools else []),
)
