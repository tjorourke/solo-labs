"""A Kubernetes SRE triage agent on Google ADK, hosted by the kagent Python runtime.

This file is the whole agent: a model, an instruction, one local tool and the MCP
tools kagent hands it. The A2A server, the streamed frames, the session and the task
the UI reads are all the runtime's work (kagent-adk), not this file's.
"""

import os

from google.adk import Agent
from google.adk.models.lite_llm import LiteLlm
from google.adk.telemetry.setup import maybe_set_otel_providers

from .gate import unhealthy
from .mcp import toolsets

# ADK creates spans for every model and tool call. They reach the collector kagent
# points at only if an OpenTelemetry provider is configured, which this does from the
# OTEL_* variables kagent injects.
os.environ.setdefault("OTEL_SERVICE_NAME", "sre-python")
maybe_set_otel_providers()

INSTRUCTION = """\
You are a Kubernetes SRE. When asked about a namespace, find the pods that are
unhealthy and explain why, from evidence.

Method: list the pods in the namespace with their phase and restart count. For each
pod call the unhealthy tool with its phase, restarts and, if it is Pending, how many
minutes it has been Pending; that tool is the rule, do not apply your own. For each
pod it marks unhealthy read the evidence that explains it: the pod description, the
last lines of its log, and the events for it. A container that never started has no
log, so use the events. Do not guess a cause you have not read.

Report format, plain text:
  <pod>  <state>  <one line cause>  <the one thing to check next>
one line per unhealthy pod, then one line naming the healthy pods. Keep it under
twenty lines. You have read-only tools and you do not change anything.
"""


def model() -> LiteLlm:
    """The model kagent asked for, read from MODEL_PROVIDER and MODEL_NAME.

    kagent injects both from the Agent record. LiteLLM takes "provider/model" and finds
    the provider's key in the environment (ANTHROPIC_API_KEY here).
    """
    provider = os.environ.get("MODEL_PROVIDER", "anthropic")
    name = os.environ.get("MODEL_NAME", "claude-haiku-4-5")
    return LiteLlm(model=f"{provider}/{name}")


root_agent = Agent(
    name="sre_triage",
    description="Kubernetes SRE triage. Reports which pods in a namespace are unhealthy, and why.",
    model=model(),
    instruction=INSTRUCTION,
    tools=[unhealthy, *toolsets()],
)
