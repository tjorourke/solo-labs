"""Tiny MCP client over streamable-HTTP JSON-RPC.

Adapted from agentic-tool-curation-kind. Supports an optional `turn` and
`extra_headers` argument on tools/call so the inspector can bump
X-Goal-Turn between scripted scenarios.
"""
from __future__ import annotations

import json
import uuid
from typing import Any

import httpx


class MCPError(Exception):
    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(f"{code} {message}")
        self.code = code
        self.message = message
        self.data = data


_SESSIONS: dict[str, str] = {}
_PROTOCOL_VERSION = "2025-03-26"


def _parse_response(text: str) -> dict:
    text = text.strip()
    if not text:
        raise MCPError(-32603, "empty response from MCP server")
    if text.startswith("{"):
        return json.loads(text)
    for line in text.splitlines():
        if line.startswith("data:"):
            return json.loads(line[len("data:"):].strip())
    raise MCPError(-32603, f"unrecognized MCP response shape: {text[:160]!r}")


def _base_headers(jwt: str, session_id: str | None = None, turn: int | None = None) -> dict[str, str]:
    h = {
        "Authorization": f"Bearer {jwt}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": _PROTOCOL_VERSION,
    }
    if session_id:
        h["Mcp-Session-Id"] = session_id
    if turn is not None:
        # Signals a new "goal turn" to the budget ext-auth. In production
        # this would be set by the orchestrator, not the user — see
        # CLAUDE.md for the trust-boundary note.
        h["X-Goal-Turn"] = str(turn)
    return h


async def _post(client: httpx.AsyncClient, url: str, body: dict, headers: dict) -> httpx.Response:
    return await client.post(url, content=json.dumps(body), headers=headers, timeout=30.0)


async def _initialize(client: httpx.AsyncClient, url: str, jwt: str) -> str:
    init_body = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "initialize",
        "params": {
            "protocolVersion": _PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "runaway-inspector-ui", "version": "0.1"},
        },
    }
    resp = await _post(client, url, init_body, _base_headers(jwt))
    if resp.status_code in (401, 403):
        raise MCPError(resp.status_code, f"gateway auth failed at initialize: HTTP {resp.status_code} {resp.text[:200]}")
    if resp.status_code >= 500:
        raise MCPError(-32603, f"upstream HTTP {resp.status_code} on initialize: {resp.text[:200]}")
    session_id = resp.headers.get("mcp-session-id") or resp.headers.get("Mcp-Session-Id") or ""
    parsed = _parse_response(resp.text)
    if "error" in parsed:
        err = parsed["error"] or {}
        raise MCPError(err.get("code", -32603), err.get("message", "initialize failed"), err.get("data"))

    notif = {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
    resp2 = await _post(client, url, notif, _base_headers(jwt, session_id))
    if resp2.status_code >= 500:
        raise MCPError(-32603, f"upstream HTTP {resp2.status_code} on notifications/initialized: {resp2.text[:200]}")
    return session_id


async def ensure_session(client: httpx.AsyncClient, url: str, jwt: str) -> str:
    """Public so the inspector can grab the session id for the budget /state probe."""
    sid = _SESSIONS.get(jwt)
    if sid is not None:
        return sid
    sid = await _initialize(client, url, jwt)
    _SESSIONS[jwt] = sid
    return sid


def invalidate(jwt: str) -> None:
    _SESSIONS.pop(jwt, None)


def session_id(jwt: str) -> str | None:
    return _SESSIONS.get(jwt)


async def call_tool(
    client: httpx.AsyncClient,
    url: str,
    jwt: str,
    name: str,
    arguments: dict | None = None,
    turn: int | None = None,
) -> dict:
    """Invoke a tool. If `turn` is set, the X-Goal-Turn header is sent so
    the ext-auth knows to bump turn counters."""
    for attempt in range(2):
        sid = await ensure_session(client, url, jwt)
        body = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        }
        resp = await _post(client, url, body, _base_headers(jwt, sid, turn=turn))
        if resp.status_code == 429:
            # Budget-extauth deny — surface the verbatim JSON body so the UI
            # can render `reason_code`, `limit`, `observed`, etc.
            raise MCPError(429, resp.text[:600])
        if resp.status_code in (401, 403):
            raise MCPError(resp.status_code, f"gateway said: HTTP {resp.status_code} {resp.text[:300]}")
        if resp.status_code in (404, 410) or (
            resp.status_code >= 400 and "session" in resp.text.lower() and attempt == 0
        ):
            invalidate(jwt)
            continue
        if resp.status_code >= 500:
            raise MCPError(-32603, f"upstream HTTP {resp.status_code}: {resp.text[:200]}")
        parsed = _parse_response(resp.text)
        if "error" in parsed:
            err = parsed["error"] or {}
            raise MCPError(err.get("code", -32603), err.get("message", "unknown"), err.get("data"))
        return parsed.get("result")
    raise MCPError(-32603, "could not establish MCP session after retry")
