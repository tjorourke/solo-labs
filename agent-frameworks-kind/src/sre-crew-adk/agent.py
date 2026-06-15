"""BYO Google ADK crew — the SRE incident crew as a coordinator + sub-agents.

ADK models multi-agent systems as an LlmAgent with sub_agents it can transfer to.
Here a coordinator delegates across the same three roles:

    sre_coordinator
      |-- diagnostician  (read tools -> root cause)
      |-- planner        (-> exact image patch)
      `-- operator       (-> applies patch_deployment_image)

The model is reached through agentgateway (ADK LiteLlm with an OpenAI-compatible
api_base -> Claude) and the tools through the gateway's /mcp route (ADK MCPToolset,
streamable HTTP). The image carries no provider key — the gateway injects it.
"""
from __future__ import annotations

import os

from google.adk.agents import LlmAgent, SequentialAgent
from google.adk.models.lite_llm import LiteLlm
from google.adk.tools.mcp_tool.mcp_toolset import (
    MCPToolset,
    StreamableHTTPConnectionParams,
)

LLM_BASE_URL = os.environ.get(
    "LLM_BASE_URL", "http://frameworks-gw.agentgateway-system.svc.cluster.local/v1"
)
MCP_URL = os.environ.get(
    "MCP_URL", "http://frameworks-gw.agentgateway-system.svc.cluster.local/mcp"
)
MODEL = os.environ.get("MODEL", "claude-haiku-4-5")


def _model() -> LiteLlm:
    # LiteLlm routes the openai/ provider to the gateway's OpenAI-compatible endpoint.
    return LiteLlm(model=f"openai/{MODEL}", api_base=LLM_BASE_URL, api_key="sk-gateway")


def _toolset() -> MCPToolset:
    return MCPToolset(connection_params=StreamableHTTPConnectionParams(url=MCP_URL))


diagnostician = LlmAgent(
    name="diagnostician",
    model=_model(),
    description="Finds the root cause of a failing workload from cluster state.",
    instruction=(
        "Inspect the failing workload in the incident namespace with your tools "
        "(pods, events, logs, deployment spec) and state the single root cause. "
        "You diagnose only."
    ),
    tools=[_toolset()],
)

planner = LlmAgent(
    name="planner",
    model=_model(),
    description="Turns a root cause into one exact image patch.",
    instruction=(
        "Given the diagnosis, state the exact remediation: the namespace, "
        "deployment name, container name, and a valid image tag to set. Use "
        "describe_deployment to confirm the current container first. Do not apply it."
    ),
    tools=[_toolset()],
)

operator = LlmAgent(
    name="operator",
    model=_model(),
    description="Applies the agreed image patch.",
    instruction=(
        "Apply the planned fix by calling patch_deployment_image with the agreed "
        "namespace, deployment, container and image, then confirm what changed."
    ),
    tools=[_toolset()],
)

# SequentialAgent runs the three roles in order, sharing session state, so the
# operator reliably runs after the plan (an LlmAgent coordinator with sub_agents
# transfers control and may stop after the plan). This is ADK's pipeline primitive.
root_agent = SequentialAgent(
    name="sre_coordinator",
    description="On-call SRE pipeline: diagnose, plan, then apply the fix.",
    sub_agents=[diagnostician, planner, operator],
)
