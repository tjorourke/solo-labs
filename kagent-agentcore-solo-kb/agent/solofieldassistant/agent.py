import os

from google.adk.agents import Agent
from google.adk.tools.mcp_tool import MCPToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPServerParams

from .bedrock_model import BedrockClaude

os.environ.setdefault("OTEL_SERVICE_NAME", "solofieldassistant")

from google.adk.telemetry.setup import maybe_set_otel_providers
maybe_set_otel_providers()


SOLO_KB_MCP_URL = os.environ.get(
    "SOLO_KB_MCP_URL",
    "https://knowledge-base.soloio-field.com/mcp",
)
BEDROCK_MODEL_ID = os.environ.get(
    "BEDROCK_MODEL_ID",
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
)
os.environ.setdefault("AWS_REGION", os.environ.get("AWS_REGION", "us-east-1"))


solo_kb_tools = MCPToolset(
    connection_params=StreamableHTTPServerParams(
        url=SOLO_KB_MCP_URL,
    ),
)


root_agent = Agent(
    name="solofieldassistant_agent",
    model=BedrockClaude(model=BEDROCK_MODEL_ID),
    description=(
        "Answers questions about Solo.io products by calling the Solo "
        "Knowledge Base via MCP."
    ),
    instruction=(
        "You are a Solo.io field engineer assistant. "
        "For any question about kgateway, agentgateway, istio, kagent, "
        "or agentregistry, call the Solo Knowledge Base tools first and "
        "answer from what you get back. "
        "When you cite a fact, name the use-case filename or CRD kind "
        "you read it from, and the product version if the tool returned one. "
        "If a tool returns no result, say so plainly. Do not invent fields, "
        "CRDs, or behaviours that the KB didn't return."
    ),
    tools=[solo_kb_tools],
)
