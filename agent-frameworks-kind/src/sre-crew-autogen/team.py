"""BYO AutoGen crew — the SRE incident crew as a RoundRobinGroupChat team.

AutoGen models a multi-agent system as a team of conversational agents. Here the
same three roles take turns until the fix is applied:

    Diagnostician -> Planner -> Operator  (round-robin, until TERMINATE)

The model is reached through agentgateway (AutoGen's OpenAIChatCompletionClient
with an OpenAI-compatible base_url -> Claude) and the tools through the gateway's
/mcp route (autogen_ext MCP tools). A non-OpenAI model name needs explicit
model_info so the client knows the model supports function calling.
"""
from __future__ import annotations

import os

from autogen_agentchat.agents import AssistantAgent
from autogen_agentchat.conditions import MaxMessageTermination, TextMentionTermination
from autogen_agentchat.teams import RoundRobinGroupChat
from autogen_core.models import ModelInfo
from autogen_ext.models.openai import OpenAIChatCompletionClient
from autogen_ext.tools.mcp import StreamableHttpServerParams, mcp_server_tools

LLM_BASE_URL = os.environ.get(
    "LLM_BASE_URL", "http://frameworks-gw.agentgateway-system.svc.cluster.local/v1"
)
MCP_URL = os.environ.get(
    "MCP_URL", "http://frameworks-gw.agentgateway-system.svc.cluster.local/mcp"
)
MODEL = os.environ.get("MODEL", "claude-haiku-4-5")


def _model_client() -> OpenAIChatCompletionClient:
    return OpenAIChatCompletionClient(
        model=MODEL,
        base_url=LLM_BASE_URL,
        api_key="sk-gateway",
        model_info=ModelInfo(
            vision=False,
            function_calling=True,
            json_output=True,
            family="unknown",
            structured_output=True,
        ),
    )


async def build_team() -> RoundRobinGroupChat:
    tools = await mcp_server_tools(StreamableHttpServerParams(url=MCP_URL))
    client = _model_client()

    diagnostician = AssistantAgent(
        "diagnostician",
        model_client=client,
        tools=tools,
        system_message=(
            "You are a Kubernetes diagnostician for the incident namespace. Inspect "
            "the failing workload (pods, events, logs, deployment spec) and state the "
            "single root cause. Diagnose only."
        ),
    )
    planner = AssistantAgent(
        "planner",
        model_client=client,
        tools=tools,
        system_message=(
            "You are an SRE remediation planner. From the diagnosis, give the exact "
            "image patch: namespace, deployment, container and a valid image tag. Use "
            "describe_deployment to confirm the container. Do not apply it."
        ),
    )
    operator = AssistantAgent(
        "operator",
        model_client=client,
        tools=tools,
        system_message=(
            "You are an SRE operator. Apply the planned fix by calling "
            "patch_deployment_image with the agreed namespace, deployment, container "
            "and image. Once the patch is confirmed, write a one-line summary and end "
            "your message with the word TERMINATE."
        ),
    )

    termination = TextMentionTermination("TERMINATE") | MaxMessageTermination(20)
    return RoundRobinGroupChat(
        [diagnostician, planner, operator], termination_condition=termination
    )
