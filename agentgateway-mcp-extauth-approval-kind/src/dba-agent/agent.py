"""dba-agent: a small BYO kagent agent that acts for the person who called it.

kagent runs this A2A server as a BYO Agent under the dba-agent ServiceAccount.
For every request it:

  1. reads the caller's bearer token from the A2A request headers
     (a2a-sdk puts the HTTP headers in the request's call context),
  2. asks Solo STS to exchange it: subject_token = the caller's Keycloak token,
     actor_token = this pod's dba-agent ServiceAccount token,
  3. opens an MCP session on agentgateway with the minted token and lets the
     model call the users-mcp tools.

No token is logged or returned. A request without a caller token is refused.
"""
from __future__ import annotations

import base64
import json
import logging
import os

import anthropic
import httpx
import uvicorn
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.apps import A2AStarletteApplication
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentSkill
from a2a.utils import new_agent_text_message
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("dba-agent")

STS_TOKEN_URL = os.environ["STS_TOKEN_URL"]
MCP_URL = os.environ["MCP_URL"]
MCP_AUDIENCE = os.environ.get("MCP_AUDIENCE", "hitl-mcp")
MODEL = os.environ.get("MODEL", "claude-haiku-4-5")
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
JWT = "urn:ietf:params:oauth:token-type:jwt"

SYSTEM = (
    "You are the DBA assistant for the platform team. You manage the users "
    "directory through the tools you are given. Look a person up with get_users "
    "before you change anything, then act on the matching id. Some tools wait "
    "for a platform reviewer; if a call is refused, say so plainly. Keep replies short."
)


def claims(token: str) -> dict:
    part = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


def caller_token(context: RequestContext) -> str | None:
    headers = (context.call_context.state.get("headers") if context.call_context else None) or {}
    value = next((v for k, v in headers.items() if k.lower() == "authorization"), "")
    scheme, _, token = value.partition(" ")
    return token.strip() if scheme.lower() == "bearer" and token.strip() else None


async def exchange(subject_token: str) -> str:
    with open(SA_TOKEN_PATH) as f:
        actor_token = f.read().strip()
    async with httpx.AsyncClient(timeout=15) as client:
        r = await client.post(STS_TOKEN_URL, data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": subject_token, "subject_token_type": JWT,
            "actor_token": actor_token, "actor_token_type": JWT,
            "audience": MCP_AUDIENCE,
        })
    if r.status_code != 200:
        raise RuntimeError(f"STS exchange refused: HTTP {r.status_code} {r.json().get('error', '')}")
    token = r.json()["access_token"]
    c = claims(token)
    log.info("STS minted token for user=%s actor=%s", c.get("preferred_username"), (c.get("act") or {}).get("sub"))
    return token


async def run(prompt: str, token: str) -> str:
    llm = anthropic.AsyncAnthropic()
    headers = {"Authorization": f"Bearer {token}"}
    async with streamablehttp_client(MCP_URL, headers=headers, timeout=30, sse_read_timeout=900) as (read, write, _):
        async with ClientSession(read, write) as mcp:
            await mcp.initialize()
            listed = await mcp.list_tools()
            tools = [{"name": t.name, "description": t.description or "", "input_schema": t.inputSchema} for t in listed.tools]
            messages = [{"role": "user", "content": prompt}]
            for _ in range(8):
                reply = await llm.messages.create(model=MODEL, max_tokens=1024, system=SYSTEM, tools=tools, messages=messages)
                messages.append({"role": "assistant", "content": reply.content})
                calls = [b for b in reply.content if b.type == "tool_use"]
                if not calls:
                    return "".join(b.text for b in reply.content if b.type == "text")
                results = []
                for call in calls:
                    log.info("tools/call %s %s", call.name, json.dumps(call.input))
                    try:
                        out = await mcp.call_tool(call.name, call.input)
                        text = "".join(getattr(c, "text", "") for c in out.content)
                        results.append({"type": "tool_result", "tool_use_id": call.id, "content": text, "is_error": bool(out.isError)})
                    except Exception as e:  # a reviewer rejection arrives as HTTP 403
                        log.info("tools/call %s failed: %s", call.name, type(e).__name__)
                        results.append({"type": "tool_result", "tool_use_id": call.id, "content": f"Refused by the gateway: {e}", "is_error": True})
                messages.append({"role": "user", "content": results})
    return "Stopped after too many tool calls."


class DbaExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        token = caller_token(context)
        log.info("request received; caller bearer token present: %s", bool(token))
        if not token:
            await event_queue.enqueue_event(new_agent_text_message(
                "I need your sign-in token to act for you. Call me with your Keycloak bearer token.",
                context.context_id, context.task_id))
            return
        try:
            text = await run(context.get_user_input(), await exchange(token))
        except Exception as e:
            log.info("request failed: %s", e)
            text = f"I could not complete that: {e}"
        await event_queue.enqueue_event(new_agent_text_message(text, context.context_id, context.task_id))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError


def main() -> None:
    card = AgentCard(
        name="dba-agent",
        description="DBA assistant that manages the users directory through MCP, acting for the person who asks.",
        url=os.environ.get("AGENT_URL", "http://localhost:8080/"),
        version="0.1.0",
        capabilities=AgentCapabilities(streaming=False),
        default_input_modes=["text"],
        default_output_modes=["text"],
        skills=[AgentSkill(id="users-admin", name="Users admin", description="Look up and remove users.", tags=["dba", "mcp"])],
    )
    app = A2AStarletteApplication(agent_card=card, http_handler=DefaultRequestHandler(DbaExecutor(), InMemoryTaskStore()))
    uvicorn.run(app.build(), host="0.0.0.0", port=int(os.getenv("PORT", "8080")))


if __name__ == "__main__":
    main()
