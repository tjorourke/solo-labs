"""BYO LangGraph chat agent — per-team budget lab.

The same image is run twice in the cluster (dba / support). The ONLY thing
that differs is the JWT mounted at LLM_JWT — every other code path is
identical. The gateway is the entire authorization + accounting story:
the agent ships an Authorization: Bearer <jwt> header on every
/v1/chat/completions call, the gateway validates the JWT, decrements the
team's token budget by the response's `usage.total_tokens`, and once the
budget is exhausted returns 429 to the next request.

This agent intentionally does NOT use ChatOpenAI / ChatAnthropic — it does a
plain httpx POST. That makes:
  - The 429 surface verbatim (no langchain retry layer eating it).
  - The wire shape trivially auditable.
  - The dependency list minimal.

There is no tool calling. The agent is a single-turn chat passthrough that
exists to demonstrate per-team token accounting, not capability composition.
"""
from __future__ import annotations

import logging
import os
from typing import Annotated, Any

import httpx
from kagent.core import KAgentConfig
from kagent.langgraph import KAgentCheckpointer
from langchain_core.messages import AIMessage, HumanMessage
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from typing_extensions import TypedDict

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────
LLM_URL = os.environ.get(
    "LLM_URL",
    "http://budgets-gateway.agentgateway-system.svc.cluster.local/v1/chat/completions",
)
MODEL = os.environ.get("MODEL", "mock-essay-7b")
LLM_JWT = os.environ.get("LLM_JWT", "")
TEAM_LABEL = os.environ.get("TEAM_LABEL", "unknown")  # dba / support — log + UI hint
REQUEST_TIMEOUT = float(os.environ.get("LLM_REQUEST_TIMEOUT", "60"))

if not LLM_JWT:
    raise RuntimeError(
        "LLM_JWT not set — agent has no identity to present to the gateway. "
        "The deployment YAML should mount a Secret created by jwt-issuer."
    )


# ── LLM call ──────────────────────────────────────────────────────────────────
async def _call_llm(messages: list[dict[str, str]]) -> str:
    """POST /v1/chat/completions through the gateway.

    On HTTP 429 (budget exhausted), surface a clear message back to the user
    rather than swallowing it. Same for transport errors.
    """
    payload = {"model": MODEL, "messages": messages}
    headers = {
        "Authorization": f"Bearer {LLM_JWT}",
        # The agent does NOT set X-Team-ID. The gateway validates the
        # JWT and stamps X-Team-ID from the `team` claim (a CEL
        # `jwt.team` transformation — see yaml/agentgateway/jwt-policy.yaml).
        # The rate-limit-service reads X-Team-ID to pick the per-team
        # token bucket, so the value can't be spoofed by a client.
        "Content-Type": "application/json",
    }
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        try:
            resp = await client.post(LLM_URL, json=payload, headers=headers)
        except httpx.HTTPError as e:
            logger.exception("transport error calling gateway")
            return f"Sorry — couldn't reach the LLM gateway: {e}"

    if resp.status_code == 429:
        logger.info("team=%s got 429 from gateway — budget exhausted", TEAM_LABEL)
        return (
            f"Sorry — your team's LLM token budget is exhausted. "
            f"Please try again later. (HTTP 429 from the gateway; "
            f"team={TEAM_LABEL!r}.)"
        )

    if resp.status_code == 401:
        return (
            "Sorry — the gateway rejected this agent's JWT. "
            "This is a deployment problem, not a budget one."
        )

    if resp.status_code >= 400:
        return f"LLM gateway returned HTTP {resp.status_code}: {resp.text[:400]}"

    try:
        body = resp.json()
    except Exception:  # noqa: BLE001
        return f"LLM gateway returned non-JSON body: {resp.text[:400]}"

    choices = body.get("choices") or []
    if not choices:
        return f"LLM gateway returned no choices in response: {body}"
    content = (choices[0].get("message") or {}).get("content") or ""

    usage = body.get("usage") or {}
    logger.info(
        "team=%s served prompt_tokens=%s completion_tokens=%s total=%s",
        TEAM_LABEL,
        usage.get("prompt_tokens"),
        usage.get("completion_tokens"),
        usage.get("total_tokens"),
    )
    return content


# ── Graph ─────────────────────────────────────────────────────────────────────
class AgentState(TypedDict):
    messages: Annotated[list, add_messages]


def _to_openai_messages(state_messages: list) -> list[dict[str, str]]:
    """Convert LangChain messages to OpenAI-style {role, content} dicts."""
    out: list[dict[str, str]] = []
    for m in state_messages:
        if isinstance(m, HumanMessage):
            role = "user"
        elif isinstance(m, AIMessage):
            role = "assistant"
        else:
            # System or tool messages we don't expect in this lab — best-effort.
            role = getattr(m, "type", "user")
            if role == "system":
                role = "system"
            elif role not in {"user", "assistant", "system"}:
                role = "user"
        out.append({"role": role, "content": str(getattr(m, "content", ""))})
    return out


async def chat(state: AgentState) -> dict[str, Any]:
    msgs = _to_openai_messages(state["messages"])
    reply = await _call_llm(msgs)
    return {"messages": [AIMessage(content=reply)]}


kagent_checkpointer = KAgentCheckpointer(
    client=httpx.AsyncClient(base_url=KAgentConfig().url),
    app_name=KAgentConfig().app_name,
)

builder = StateGraph(AgentState)
builder.add_node("chat", chat)
builder.add_edge(START, "chat")
builder.add_edge("chat", END)

graph = builder.compile(checkpointer=kagent_checkpointer)
