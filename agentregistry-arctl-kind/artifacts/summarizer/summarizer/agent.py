import os

from google.adk import Agent
from google.adk.models.lite_llm import LiteLlm

from .mcp_tools import get_mcp_tools
from .prompts_loader import build_instruction
from .skill_loader import load_baked_skills

# Initialize OpenTelemetry
# Set service name from environment variable for OpenTelemetry
os.environ.setdefault('OTEL_SERVICE_NAME', 'summarizer')

from google.adk.telemetry.setup import maybe_set_otel_providers
maybe_set_otel_providers()


def create_model():
    """Use an Anthropic model via LiteLLM."""
    return LiteLlm(model="anthropic/claude-haiku-4-5")


# Base instruction: who the agent is, plus the baked-in summary-style skill that
# tells it exactly how to format a summary and which textkit tools to call.
_ROLE = (
    "You are a summarization assistant. The user gives you a block of text and "
    "you return a summary. You have textkit MCP tools available: word_count and "
    "extract_links. Always follow the summary house style below."
)
_INSTRUCTION = _ROLE + "\n\n" + load_baked_skills()


mcp_tools = get_mcp_tools()
root_agent = Agent(
    model=create_model(),
    name="summarizer_agent",
    description="Summarizes pasted text in the house format, using textkit MCP tools.",
    instruction=build_instruction(_INSTRUCTION),
    tools=(mcp_tools if mcp_tools else []),
)
