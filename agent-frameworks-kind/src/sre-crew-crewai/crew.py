"""BYO CrewAI crew — the SRE incident crew as roles + tasks.

CrewAI models a crew as named agents (role / goal / backstory) executing a list of
tasks. Here the same three roles run as a sequential process:

    Diagnostician  -> finds the root cause from cluster state
    Planner        -> turns it into one exact image patch
    Operator       -> applies the patch (patch_deployment_image)

The LLM is reached through agentgateway (crewai.LLM with an OpenAI-compatible
base_url -> Claude) and the tools through the gateway's /mcp route (crewai_tools
MCPServerAdapter). The Operator's patch call is the mutating one; the gateway
ext-auth HITL policy (07-augment.sh) is the approval gate for the BYO crews.
"""
from __future__ import annotations

import os

from crewai import LLM, Agent, Crew, Process, Task
from crewai_tools import MCPServerAdapter

LLM_BASE_URL = os.environ.get(
    "LLM_BASE_URL", "http://frameworks-gw.agentgateway-system.svc.cluster.local/v1"
)
MCP_URL = os.environ.get(
    "MCP_URL", "http://frameworks-gw.agentgateway-system.svc.cluster.local/mcp"
)
MODEL = os.environ.get("MODEL", "claude-haiku-4-5")

# crewai uses LiteLLM under the hood; the openai/ prefix + base_url routes through
# the gateway's OpenAI-compatible endpoint. The key is a placeholder — the gateway
# injects the real provider credential.
_llm = LLM(model=f"openai/{MODEL}", base_url=LLM_BASE_URL, api_key="sk-gateway")

# Tools from the k8s-ops MCP server, via the gateway. Opened once for the life of
# the process (the agent server is long-lived).
_tools = MCPServerAdapter({"url": MCP_URL, "transport": "streamable-http"}).tools


def build_crew() -> Crew:
    diagnostician = Agent(
        role="Kubernetes Diagnostician",
        goal="Find the single root cause of the failing workload in the incident namespace.",
        backstory="A site reliability engineer who reads pod state, events and logs to pinpoint why a workload will not start.",
        tools=_tools,
        llm=_llm,
        allow_delegation=False,
        verbose=True,
    )
    planner = Agent(
        role="Remediation Planner",
        goal="Turn the root cause into one concrete, minimal image patch.",
        backstory="An SRE who proposes the smallest safe change: the namespace, deployment, container and exact image tag to set.",
        tools=_tools,
        llm=_llm,
        allow_delegation=False,
        verbose=True,
    )
    operator = Agent(
        role="SRE Operator",
        goal="Apply the agreed image patch so the workload recovers.",
        backstory="An operator who executes the approved remediation against the cluster.",
        tools=_tools,
        llm=_llm,
        allow_delegation=False,
        verbose=True,
    )

    diagnose = Task(
        description=(
            "The checkout deployment in the incident namespace is not coming up. "
            "Inspect pods, events, logs and the deployment spec, and state the single "
            "root cause."
        ),
        expected_output="One or two sentences naming the root cause.",
        agent=diagnostician,
    )
    plan = Task(
        description=(
            "From the diagnosis, give the exact remediation as an image patch: the "
            "namespace, deployment name, container name, and a valid image tag to set."
        ),
        expected_output="The precise patch arguments (namespace, name, container, image).",
        agent=planner,
        context=[diagnose],
    )
    apply = Task(
        description=(
            "Apply the planned fix by calling patch_deployment_image with the agreed "
            "namespace, deployment, container and image. Then confirm what changed."
        ),
        expected_output="Confirmation that the deployment image was patched.",
        agent=operator,
        context=[plan],
    )

    return Crew(
        agents=[diagnostician, planner, operator],
        tasks=[diagnose, plan, apply],
        process=Process.sequential,
        verbose=True,
    )
