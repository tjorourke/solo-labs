"""BYO LangGraph agent — DBA Assistant.

Adapts the kagent canonical hitl-tools sample
(python/samples/langgraph/hitl-tools/hitl_tools/agent.py) to:

  - Load tools from two MCP servers reached via the agentgateway, so every
    tool call goes through the same gateway as the declarative agent. The
    gateway HITL on /privileged fires identically — the agent has no
    knowledge of it.
  - Intercept `truncate_table` with LangGraph `interrupt()` to drive the
    agent-side HITL card in the kagent dashboard. The payload shape
    (`action_requests` with name/args/id) is what the kagent LangGraph
    executor expects — anything else won't render as an actionable card.

The agent talks to /privileged/mcp directly — both for the MCP session
handshake AND for tools/call. The gate doesn't park bootstrap traffic
because hitl-extauth only parks JSON-RPC tools/call frames; initialize and
tools/list pass through. See ../../yaml/agentgateway/extauth-policy.yaml
and src/hitl-extauth/main.go for the gate's filter.

See ../declarative.yaml for the equivalent declarative agent. The two are
behaviourally identical from a user's perspective.
"""
from __future__ import annotations

import asyncio
import logging
import os
from typing import Annotated, Any

import httpx
from kagent.core import KAgentConfig
from kagent.langgraph import KAgentCheckpointer
from langchain_anthropic import ChatAnthropic
from langchain_core.messages import AIMessage, ToolMessage
from langchain_mcp_adapters.client import MultiServerMCPClient
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.types import interrupt
from typing_extensions import TypedDict

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(__name__)

# ── Config ───────────────────────────────────────────────────────────────────

PUBLIC_MCP_URL = os.environ.get(
    "OPS_TOOLS_PUBLIC_URL",
    "http://hitl-gateway.agentgateway-system.svc.cluster.local/public/mcp",
)
PRIVILEGED_MCP_URL = os.environ.get(
    "OPS_TOOLS_PRIVILEGED_URL",
    "http://hitl-gateway.agentgateway-system.svc.cluster.local/privileged/mcp",
)
MODEL = os.environ.get("MODEL", "claude-haiku-4-5")

# Agent-side HITL: every call to one of these tools pauses for approval in
# the chat. Mirrors `requireApproval: [truncate_table]` in declarative.yaml.
TOOLS_REQUIRING_APPROVAL = {"truncate_table"}


# ── Load MCP tools (with retry — gateway may not be ready at first pod start) ─


async def _load_tools_with_retry() -> list:
    client = MultiServerMCPClient(
        {
            "public": {"url": PUBLIC_MCP_URL, "transport": "streamable_http"},
            "privileged": {"url": PRIVILEGED_MCP_URL, "transport": "streamable_http"},
        }
    )
    last_err: Exception | None = None
    for attempt in range(1, 21):  # ~60s of total backoff
        try:
            tools = await client.get_tools()
            if tools:
                logger.info(
                    "loaded %d MCP tools: %s", len(tools), [t.name for t in tools]
                )
                return tools
            last_err = RuntimeError("MCP returned zero tools")
        except Exception as e:  # noqa: BLE001 — we want to retry on any flake
            last_err = e
        logger.info("MCP tool load attempt %d failed (%s); retrying", attempt, last_err)
        await asyncio.sleep(3)
    raise RuntimeError(f"could not load MCP tools after retries: {last_err}")


def _bootstrap_tools() -> list:
    """Load MCP tools at module import.

    No running event loop at import time (uvicorn starts one later in cli.py),
    so asyncio.run() works here. If tool loading fails after retries, the
    process exits — the deployment will CrashLoopBackoff until the gateway
    is reachable.
    """
    return asyncio.run(_load_tools_with_retry())


TOOLS = _bootstrap_tools()
TOOL_MAP = {t.name: t for t in TOOLS}


# ── LLM + checkpointer ────────────────────────────────────────────────────────

llm = ChatAnthropic(model=MODEL).bind_tools(TOOLS)

kagent_checkpointer = KAgentCheckpointer(
    client=httpx.AsyncClient(base_url=KAgentConfig().url),
    app_name=KAgentConfig().app_name,
)


# ── Graph ─────────────────────────────────────────────────────────────────────


class AgentState(TypedDict):
    messages: Annotated[list, add_messages]


async def call_model(state: AgentState) -> dict[str, Any]:
    response = await llm.ainvoke(state["messages"])
    return {"messages": [response]}


async def run_tools(state: AgentState) -> dict[str, Any]:
    """Execute tool calls, with HITL approval for the dangerous ones.

    Each tool call is either:
      - In TOOLS_REQUIRING_APPROVAL → interrupt() pauses the graph; the kagent
        executor converts the interrupt into an A2A `input_required` event
        with the `adk_request_confirmation` DataPart that the dashboard
        renders as an actionable approval card.
      - Not in the approval set → executed directly. (Gateway HITL, if
        applicable, fires at the HTTP layer below this code — we never see it.)
    """
    last_message = state["messages"][-1]
    assert isinstance(last_message, AIMessage) and last_message.tool_calls

    results: list[ToolMessage] = []
    for tool_call in last_message.tool_calls:
        name = tool_call["name"]
        args = tool_call["args"]
        call_id = tool_call["id"]

        if name in TOOLS_REQUIRING_APPROVAL:
            decision = interrupt(
                {
                    "action_requests": [
                        {"name": name, "args": args, "id": call_id}
                    ]
                }
            )
            decision_type = (
                decision.get("decision_type", "reject")
                if isinstance(decision, dict)
                else "reject"
            )
            if decision_type != "approve":
                reasons = (
                    decision.get("rejection_reasons", {})
                    if isinstance(decision, dict)
                    else {}
                )
                reason = reasons.get("*", "") if isinstance(reasons, dict) else ""
                msg = "Tool call was rejected by user."
                if reason:
                    msg += f" Reason: {reason}"
                results.append(ToolMessage(content=msg, tool_call_id=call_id, name=name))
                continue

        tool_fn = TOOL_MAP[name]
        try:
            result = await tool_fn.ainvoke(args)
            results.append(ToolMessage(content=str(result), tool_call_id=call_id, name=name))
        except Exception as e:  # noqa: BLE001
            # Gateway HITL rejections come back as HTTP 403; surface verbatim
            # rather than swallowing.
            results.append(
                ToolMessage(content=f"Tool call failed: {e}", tool_call_id=call_id, name=name)
            )
    return {"messages": results}


def should_continue(state: AgentState) -> str:
    last = state["messages"][-1]
    if isinstance(last, AIMessage) and last.tool_calls:
        return "tools"
    return END


builder = StateGraph(AgentState)
builder.add_node("agent", call_model)
builder.add_node("tools", run_tools)
builder.add_edge(START, "agent")
builder.add_conditional_edges("agent", should_continue, {"tools": "tools", END: END})
builder.add_edge("tools", "agent")

graph = builder.compile(checkpointer=kagent_checkpointer)
