"""BYO LangGraph crew — the SRE incident crew as a stateful multi-node graph.

This is the LangGraph half of the LangChain-vs-LangGraph comparison. Where the
LangChain crew (../sre-crew-langchain) is one AgentExecutor running a single
tool-calling loop, this is an explicit StateGraph with named nodes and edges:

    diagnose  <-> diag_tools        (Diagnostician: loop until root cause found)
        |
        v
      plan                          (Remediation planner: force one patch proposal)
        |
        v
     review   --(interrupt)-->      (Reviewer: human approves the patch in chat)
        |
        v
      apply                         (apply the patch if approved)
        |
        v
    summarize -> END                (write the incident summary)

State persists in kagent via KAgentCheckpointer, so the run survives the pause at
`review`. The LLM is reached through agentgateway (OpenAI-compatible -> Claude) and
the tools through the same gateway's /mcp route — the agent code knows neither the
provider key nor the real model endpoint.
"""
from __future__ import annotations

import asyncio
import logging
import os
from typing import Annotated, Any

from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
from langchain_mcp_adapters.client import MultiServerMCPClient
from langchain_openai import ChatOpenAI
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.types import interrupt
from typing_extensions import TypedDict

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(__name__)

# ── Config ───────────────────────────────────────────────────────────────────
# LLM through the gateway: a plain OpenAI client whose base_url is the gateway's
# /v1 route. The gateway translates OpenAI <-> Anthropic and injects the key.
LLM_BASE_URL = os.environ.get(
    "LLM_BASE_URL", "http://frameworks-gw.agentgateway-system.svc.cluster.local/v1"
)
MCP_URL = os.environ.get(
    "MCP_URL", "http://frameworks-gw.agentgateway-system.svc.cluster.local/mcp"
)
MODEL = os.environ.get("MODEL", "claude-haiku-4-5")
MUTATING_TOOL = "patch_deployment_image"


# ── Load MCP tools (retry — the gateway may not be ready at first pod start) ───
async def _load_tools_with_retry() -> list:
    client = MultiServerMCPClient(
        {"k8s-ops": {"url": MCP_URL, "transport": "streamable_http"}}
    )
    last_err: Exception | None = None
    for attempt in range(1, 21):  # ~60s of backoff
        try:
            tools = await client.get_tools()
            if tools:
                logger.info("loaded %d MCP tools: %s", len(tools), [t.name for t in tools])
                return tools
            last_err = RuntimeError("MCP returned zero tools")
        except Exception as e:  # noqa: BLE001 — retry on any flake
            last_err = e
        logger.info("MCP tool load attempt %d failed (%s); retrying", attempt, last_err)
        await asyncio.sleep(3)
    raise RuntimeError(f"could not load MCP tools after retries: {last_err}")


TOOLS = asyncio.run(_load_tools_with_retry())
TOOL_MAP = {t.name: t for t in TOOLS}
READ_TOOLS = [t for t in TOOLS if t.name != MUTATING_TOOL]

# ── LLMs (all through the gateway) ─────────────────────────────────────────────
_common = dict(model=MODEL, base_url=LLM_BASE_URL, api_key="sk-gateway", temperature=0)
llm_diagnose = ChatOpenAI(**_common).bind_tools(READ_TOOLS)
# Force exactly one patch proposal so `plan` always yields a reviewable tool call.
llm_plan = ChatOpenAI(**_common).bind_tools([TOOL_MAP[MUTATING_TOOL]], tool_choice=MUTATING_TOOL)
llm_summarize = ChatOpenAI(**_common)

# In-pod checkpointer. interrupt()/resume need a checkpointer to persist the paused
# state; MemorySaver keeps it in the agent pod (single replica), which keeps the
# crew self-contained. kagent's session-backed KAgentCheckpointer is the persistent
# alternative, but its checkpoint API is authenticated on the enterprise controller
# and the OSS LangGraph package does not yet propagate the agent session to it.
checkpointer = MemorySaver()

DIAGNOSE_SYS = (
    "You are a Kubernetes diagnostician for the incident namespace. Inspect the "
    "failing workload with your tools (pods, events, logs, deployment spec) and "
    "state the single root cause. When you are confident, stop calling tools and "
    "reply with the root cause in one or two sentences."
)
PLAN_SYS = (
    "You are an SRE remediation planner. From the diagnosis above, call "
    "patch_deployment_image with the exact namespace, deployment name, container "
    "name, and a valid image tag that fixes the incident."
)
SUMMARIZE_SYS = (
    "Write a short incident summary: what broke, the root cause, and the fix that "
    "was applied (or that the reviewer rejected). Three sentences at most."
)


# ── Graph ──────────────────────────────────────────────────────────────────────
class CrewState(TypedDict):
    messages: Annotated[list, add_messages]


async def diagnose(state: CrewState) -> dict[str, Any]:
    msgs = [HumanMessage(content=DIAGNOSE_SYS)] + state["messages"]
    return {"messages": [await llm_diagnose.ainvoke(msgs)]}


async def diag_tools(state: CrewState) -> dict[str, Any]:
    last = state["messages"][-1]
    results: list[ToolMessage] = []
    for call in last.tool_calls:
        tool = TOOL_MAP.get(call["name"])
        try:
            out = await tool.ainvoke(call["args"])
        except Exception as e:  # noqa: BLE001
            out = f"tool error: {e}"
        results.append(ToolMessage(content=str(out), tool_call_id=call["id"], name=call["name"]))
    return {"messages": results}


def after_diagnose(state: CrewState) -> str:
    last = state["messages"][-1]
    return "diag_tools" if isinstance(last, AIMessage) and last.tool_calls else "plan"


async def plan(state: CrewState) -> dict[str, Any]:
    msgs = [HumanMessage(content=PLAN_SYS)] + state["messages"]
    return {"messages": [await llm_plan.ainvoke(msgs)]}


async def review(state: CrewState) -> dict[str, Any]:
    """The Reviewer role. Pause the graph until a human approves the patch. The
    payload shape (action_requests with name/args/id) is what the kagent LangGraph
    executor turns into an actionable approval card in the dashboard."""
    proposal = state["messages"][-1]
    call = proposal.tool_calls[0]
    decision = interrupt(
        {"action_requests": [{"name": call["name"], "args": call["args"], "id": call["id"]}]}
    )
    decision_type = decision.get("decision_type", "reject") if isinstance(decision, dict) else "reject"

    if decision_type != "approve":
        reasons = decision.get("rejection_reasons", {}) if isinstance(decision, dict) else {}
        reason = reasons.get("*", "") if isinstance(reasons, dict) else ""
        content = "Patch rejected by reviewer." + (f" Reason: {reason}" if reason else "")
        return {"messages": [ToolMessage(content=content, tool_call_id=call["id"], name=call["name"])]}

    try:
        out = await TOOL_MAP[MUTATING_TOOL].ainvoke(call["args"])
    except Exception as e:  # noqa: BLE001
        out = f"patch failed: {e}"
    return {"messages": [ToolMessage(content=str(out), tool_call_id=call["id"], name=call["name"])]}


async def summarize(state: CrewState) -> dict[str, Any]:
    msgs = [HumanMessage(content=SUMMARIZE_SYS)] + state["messages"]
    return {"messages": [await llm_summarize.ainvoke(msgs)]}


builder = StateGraph(CrewState)
builder.add_node("diagnose", diagnose)
builder.add_node("diag_tools", diag_tools)
builder.add_node("plan", plan)
builder.add_node("review", review)
builder.add_node("summarize", summarize)
builder.add_edge(START, "diagnose")
builder.add_conditional_edges("diagnose", after_diagnose, {"diag_tools": "diag_tools", "plan": "plan"})
builder.add_edge("diag_tools", "diagnose")
builder.add_edge("plan", "review")
builder.add_edge("review", "summarize")
builder.add_edge("summarize", END)

graph = builder.compile(checkpointer=checkpointer)
