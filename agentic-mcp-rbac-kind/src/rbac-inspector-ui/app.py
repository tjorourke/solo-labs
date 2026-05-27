"""rbac-inspector-ui — single-page demo for per-identity MCP tool RBAC.

Three identities (alice / bob / carol) are baked into the UI. Switching the
"Acting as" dropdown changes which JWT the UI presents to the gateway on
every subsequent call. The same gateway path serves all three identities;
what changes is what the gateway returns from `tools/list` (and refuses on
`tools/call`).

Architecture, top-down:

  - GET /              → full page with the dropdown defaulted to alice
  - GET /tools?user=X  → HTMX swap: re-render the visible-tools panel and
                          the (Alice / Bob / Carol) identity card
  - POST /chat         → run a Claude ReAct loop with the currently-visible
                          tools as Claude's `tools` parameter; render the
                          chat fragment
  - POST /attack/{tool}?user=X → BYPASS Claude entirely and POST tools/call
                          for `tool` with X's JWT, so the user can see the
                          gateway's verbatim -32602 response when a hidden
                          tool is called

The chat is stateful per-(server, identity). The chat history is wiped on
every identity switch (the UI fires /tools on dropdown change; the history
resets server-side on that path).
"""
from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any

import httpx
from anthropic import Anthropic
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import mcp_client

# ── config ───────────────────────────────────────────────────────────────────
MCP_GATEWAY_URL = os.environ.get(
    "MCP_GATEWAY_URL",
    "http://rbac-gateway.agentgateway-system.svc.cluster.local/mcp/",
)
MODEL = os.environ.get("MODEL", "claude-haiku-4-5")
JWT_PATH = os.environ.get("JWT_PATH", "/etc/jwts")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("rbac-inspector-ui")

USERS = ["alice", "bob", "carol"]

# The full list of tool names from src/ops-tools/server.py. Used to show
# "you don't see these" greys in the panel — the UI knows the universe but
# only what the gateway returns is in the "Visible" bucket for this identity.
ALL_TOOL_NAMES = [
    "read_orders",
    "read_customers",
    "truncate_table",
    "run_migration",
    "get_secrets",
    "audit_log",
]

# Identity claim cheat-sheet (matches src/jwt-issuer/main.go). Used only in
# the UI's "Identity" card — the gateway is the authority, we just render.
IDENTITY_CLAIMS = {
    "alice": {"team": "platform", "groups": ["admin"]},
    "bob":   {"team": "dev",      "groups": ["dev"]},
    "carol": {"team": "intern",   "groups": ["intern"]},
}

# ── module-level state ──────────────────────────────────────────────────────
# In-process per-identity chat transcripts. Single-pod demo; not multi-replica.
# Wiped whenever the user switches identity via /tools.
_CHAT: dict[str, list[dict]] = {u: [] for u in USERS}

# tools/list cache to avoid hammering the gateway. Keyed by user. Each entry is
# (timestamp, tools list). 5-second TTL is plenty for chat-cadence calls and
# still feels instant when flipping the dropdown.
_TOOLS_CACHE: dict[str, tuple[float, list[dict]]] = {}
_TOOLS_TTL = 5.0


def _read_jwt(user: str) -> str:
    """Mounted Secret → string token. One file per identity under JWT_PATH."""
    path = Path(JWT_PATH) / user
    try:
        return path.read_text().strip()
    except FileNotFoundError:
        raise HTTPException(
            status_code=500,
            detail=(
                f"JWT for {user!r} not found at {path}. Check the Deployment "
                f"mounts Secrets jwt-alice/jwt-bob/jwt-carol under {JWT_PATH}."
            ),
        )


async def _fetch_tools(http: httpx.AsyncClient, user: str) -> list[dict]:
    """tools/list for `user`, with a 5s cache. Returns the raw tool dicts."""
    now = time.monotonic()
    cached = _TOOLS_CACHE.get(user)
    if cached and (now - cached[0]) < _TOOLS_TTL:
        return cached[1]
    jwt = _read_jwt(user)
    tools = await mcp_client.list_tools(http, MCP_GATEWAY_URL, jwt)
    _TOOLS_CACHE[user] = (now, tools)
    return tools


def _claude_tools(tools: list[dict]) -> list[dict]:
    """Convert MCP tool descriptions to Claude's tool schema.

    MCP tools/list returns `name`, `description`, `inputSchema`. Claude's
    Messages API wants `name`, `description`, `input_schema`. They're the
    same JSON shape — just the key name differs.
    """
    out = []
    for t in tools:
        out.append({
            "name": t.get("name", ""),
            "description": t.get("description", "") or "",
            "input_schema": t.get("inputSchema", {"type": "object", "properties": {}}),
        })
    return out


def _truncate(s: str, n: int = 800) -> str:
    s = str(s)
    return s if len(s) <= n else s[:n] + f"… ({len(s) - n} chars truncated)"


async def _run_react_loop(
    http: httpx.AsyncClient,
    user: str,
    user_message: str,
) -> list[dict]:
    """Run one round of the chat: Claude → optional tool_use → tool_result → …

    Returns the list of new transcript entries to append (each a dict with
    `role` and rendered fields). We *also* record the actual Anthropic API
    messages list separately so we can keep multi-turn context — but for
    the demo the per-message turn is small, so we re-build the API
    `messages` from `_CHAT[user]` on each call.

    Loop control: at most 6 tool-call iterations per user turn (a tight cap
    is fine for a demo where 0-2 tools per turn is the usual pattern).
    """
    tools = await _fetch_tools(http, user)
    claude_tools = _claude_tools(tools)
    visible_names = {t["name"] for t in claude_tools}

    # Build the Anthropic message list from prior history + new user message.
    api_messages: list[dict] = []
    for entry in _CHAT[user]:
        # Only include the wire-shape entries (user/assistant). Gateway-error
        # and "tool_call" UI rows are display-only and aren't sent to Claude.
        if entry["role"] == "user":
            api_messages.append({"role": "user", "content": entry["text"]})
        elif entry["role"] == "assistant":
            api_messages.append({"role": "assistant", "content": entry["text"]})
    api_messages.append({"role": "user", "content": user_message})

    new_entries: list[dict] = [{"role": "user", "text": user_message}]

    if not ANTHROPIC_API_KEY:
        new_entries.append({
            "role": "error",
            "text": "ANTHROPIC_API_KEY is not set in the rbac-inspector-ui Deployment. "
                    "Add it as an env var from a Secret and restart the pod.",
        })
        return new_entries

    client = Anthropic(api_key=ANTHROPIC_API_KEY)

    system_prompt = (
        "You are a small DBA assistant. You have access to a set of database tools "
        "exposed via MCP. When asked about your tools, list them by name. When asked "
        "to act, call the appropriate tool. If a tool call fails, surface the error "
        "verbatim to the user — don't retry blindly. Keep replies brief."
    )

    for _ in range(6):
        # Anthropic's SDK is synchronous; the call is fast enough for the
        # demo. If you swap to a higher-traffic path, use httpx + the
        # async REST endpoint.
        resp = client.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=system_prompt,
            tools=claude_tools if claude_tools else None,
            messages=api_messages,
        )

        # Render the assistant's text blocks (if any) into the transcript.
        text_chunks = [
            block.text for block in resp.content if getattr(block, "type", "") == "text"
        ]
        if text_chunks:
            new_entries.append({"role": "assistant", "text": "\n".join(text_chunks)})

        # Collect any tool_use blocks the model emitted.
        tool_uses = [b for b in resp.content if getattr(b, "type", "") == "tool_use"]
        if not tool_uses:
            break

        # Add the assistant turn (with tool_use blocks) to the api_messages
        # exactly as the SDK returned it, so the follow-up tool_result blocks
        # have valid tool_use_id references.
        api_messages.append({"role": "assistant", "content": resp.content})

        tool_result_blocks: list[dict] = []
        for tu in tool_uses:
            name = tu.name
            args = tu.input or {}
            new_entries.append({
                "role": "tool_call",
                "tool": name,
                "args_json": json.dumps(args, indent=2),
            })

            if name not in visible_names:
                # Belt-and-braces — the LLM was bound only with visible tools,
                # so this shouldn't fire under normal conditions. If the model
                # ever invents a tool name we don't have, treat it as a
                # local error rather than calling the gateway with garbage.
                err_msg = f"Unknown tool {name!r} — not in the visible tool set."
                new_entries.append({"role": "gateway_error", "text": err_msg})
                tool_result_blocks.append({
                    "type": "tool_result",
                    "tool_use_id": tu.id,
                    "is_error": True,
                    "content": err_msg,
                })
                continue

            try:
                result = await mcp_client.call_tool(
                    http, MCP_GATEWAY_URL, _read_jwt(user), name, args
                )
                # FastMCP returns `content: [{type: "text", text: "..."}]`.
                rendered = _render_tool_result(result)
                new_entries.append({"role": "tool_result", "text": _truncate(rendered)})
                tool_result_blocks.append({
                    "type": "tool_result",
                    "tool_use_id": tu.id,
                    "content": rendered,
                })
            except mcp_client.MCPError as e:
                msg = f"gateway said: JSON-RPC {e.code} {e.message}"
                new_entries.append({"role": "gateway_error", "text": msg})
                tool_result_blocks.append({
                    "type": "tool_result",
                    "tool_use_id": tu.id,
                    "is_error": True,
                    "content": msg,
                })

        api_messages.append({"role": "user", "content": tool_result_blocks})

        # If the model stopped naturally (`end_turn`) and there were no tool
        # uses, we already broke above. If it stopped with `tool_use`, loop.
        if resp.stop_reason != "tool_use":
            break

    return new_entries


def _render_tool_result(result: dict) -> str:
    """Pull text out of an MCP tools/call result. Falls back to JSON dump."""
    content = result.get("content") if isinstance(result, dict) else None
    if isinstance(content, list):
        chunks = []
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                chunks.append(c.get("text", ""))
            else:
                chunks.append(json.dumps(c))
        return "\n".join(chunks).strip() or json.dumps(result)
    return json.dumps(result, indent=2)


# ── FastAPI app ──────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).parent
app = FastAPI(title="rbac-inspector-ui")
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))


@app.get("/healthz", response_class=PlainTextResponse)
def healthz() -> str:
    return "ok"


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    default_user = USERS[0]
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "users": USERS,
            "default_user": default_user,
            "claims": IDENTITY_CLAIMS[default_user],
            "all_tool_names": ALL_TOOL_NAMES,
        },
    )


@app.get("/tools", response_class=HTMLResponse)
async def tools(request: Request, user: str = "alice") -> HTMLResponse:
    """Re-render the tool panel + identity card for `user`.

    Also resets the chat transcript for this identity — the dropdown is the
    "switch identity" gesture and the transcript is identity-scoped.
    """
    if user not in USERS:
        raise HTTPException(404, f"unknown user {user!r}")
    _CHAT[user] = []
    _TOOLS_CACHE.pop(user, None)

    async with httpx.AsyncClient() as http:
        try:
            tools_list = await _fetch_tools(http, user)
            visible = [t.get("name") for t in tools_list]
            hidden = [n for n in ALL_TOOL_NAMES if n not in visible]
            descriptions = {t.get("name"): (t.get("description") or "") for t in tools_list}
            err = None
        except mcp_client.MCPError as e:
            visible, hidden, descriptions = [], list(ALL_TOOL_NAMES), {}
            err = f"gateway {e.code}: {e.message}"
        except Exception as e:  # noqa: BLE001
            visible, hidden, descriptions = [], list(ALL_TOOL_NAMES), {}
            err = f"request failed: {e!r}"

    return templates.TemplateResponse(
        "tools.html",
        {
            "request": request,
            "user": user,
            "claims": IDENTITY_CLAIMS[user],
            "visible": visible,
            "hidden": hidden,
            "descriptions": descriptions,
            "all_tool_names": ALL_TOOL_NAMES,
            "error": err,
        },
    )


@app.post("/chat", response_class=HTMLResponse)
async def chat(
    request: Request,
    user: str = Form(...),
    message: str = Form(...),
) -> HTMLResponse:
    if user not in USERS:
        raise HTTPException(404, f"unknown user {user!r}")
    message = (message or "").strip()
    if not message:
        # Render the existing transcript without appending a blank turn.
        return templates.TemplateResponse(
            "chat.html",
            {"request": request, "user": user, "messages": _CHAT[user]},
        )

    async with httpx.AsyncClient() as http:
        entries = await _run_react_loop(http, user, message)

    _CHAT[user].extend(entries)
    return templates.TemplateResponse(
        "chat.html",
        {"request": request, "user": user, "messages": _CHAT[user]},
    )


@app.post("/attack/{tool_name}", response_class=HTMLResponse)
async def attack(request: Request, tool_name: str, user: str = "bob") -> HTMLResponse:
    """BYPASS Claude — POST tools/call directly with the chosen JWT.

    This demonstrates the gateway-side enforcement: even when a caller
    constructs the JSON-RPC call themselves (the LLM is out of the loop),
    the gateway returns -32602 Unknown tool for tools the identity can't see.
    The response body is rendered verbatim in the chat.
    """
    if user not in USERS:
        raise HTTPException(404, f"unknown user {user!r}")

    # Mock args per tool — purely so the attack call has a plausible body.
    mock_args = {
        "get_secrets": {"key": "db.password"},
        "audit_log": {},
        "truncate_table": {"table": "orders"},
        "run_migration": {"version": "v3"},
        "read_orders": {"limit": 5},
        "read_customers": {"limit": 5},
    }.get(tool_name, {})

    _CHAT[user].append({
        "role": "attack",
        "text": f"[direct] POST tools/call name={tool_name} args={json.dumps(mock_args)}",
    })

    async with httpx.AsyncClient() as http:
        try:
            result = await mcp_client.call_tool(
                http, MCP_GATEWAY_URL, _read_jwt(user), tool_name, mock_args
            )
            _CHAT[user].append({
                "role": "tool_result",
                "text": _truncate(_render_tool_result(result)),
            })
        except mcp_client.MCPError as e:
            _CHAT[user].append({
                "role": "gateway_error",
                "text": f"gateway said: JSON-RPC {e.code} {e.message}",
            })

    return templates.TemplateResponse(
        "chat.html",
        {"request": request, "user": user, "messages": _CHAT[user]},
    )
