"""Tiny MCP client over streamable-HTTP JSON-RPC.

Lifted from agentic-mcp-rbac-kind/src/rbac-inspector-ui/mcp_client.py and
trimmed — same shape, just used to drive `initialize` + `tools/list` +
`tools/call` against the gateway with a chosen JWT.

Sessions
--------
Enterprise agentgateway enforces the MCP streamable-HTTP session protocol:
client MUST initialize first, capture Mcp-Session-Id from the response,
send notifications/initialized, then include Mcp-Session-Id on every
subsequent tools/list / tools/call. We do one init per JWT and cache the
session in-process.
"""
from __future__ import annotations

import json
import uuid
from typing import Any

import httpx


class MCPError(Exception):
    """A JSON-RPC error response from the MCP server (or gateway)."""

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
    raise MCPError(-32603, f"unrecognized MCP response shape: {text[:120]!r}")


def _base_headers(jwt: str, session_id: str | None = None, intent: str | None = None) -> dict[str, str]:
    h = {
        "Authorization": f"Bearer {jwt}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": _PROTOCOL_VERSION,
    }
    if session_id:
        h["Mcp-Session-Id"] = session_id
    if intent:
        # The gateway validates the JWT (which carries intent), then strips
        # Authorization before forwarding to ext-auth. We carry the intent
        # as a separate non-authoritative header so the ext-auth can see it.
        # In a real deployment, configure the gateway's JWT filter to forward
        # validated claims as headers instead — that's tamper-proof.
        h["X-MCP-Intent"] = intent
    return h


async def _post(client: httpx.AsyncClient, url: str, body: dict, headers: dict) -> httpx.Response:
    return await client.post(url, content=json.dumps(body), headers=headers, timeout=30.0)


async def _initialize(client: httpx.AsyncClient, url: str, jwt: str, intent: str | None = None) -> str:
    init_body = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "initialize",
        "params": {
            "protocolVersion": _PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "curation-inspector-ui", "version": "0.1"},
        },
    }
    resp = await _post(client, url, init_body, _base_headers(jwt, intent=intent))
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
    resp2 = await _post(client, url, notif, _base_headers(jwt, session_id, intent=intent))
    if resp2.status_code >= 500:
        raise MCPError(-32603, f"upstream HTTP {resp2.status_code} on notifications/initialized: {resp2.text[:200]}")
    return session_id


async def _ensure_session(client: httpx.AsyncClient, url: str, jwt: str, intent: str | None = None) -> str:
    sid = _SESSIONS.get(jwt)
    if sid is not None:
        return sid
    sid = await _initialize(client, url, jwt, intent=intent)
    _SESSIONS[jwt] = sid
    return sid


def invalidate(jwt: str) -> None:
    _SESSIONS.pop(jwt, None)


def session_id(jwt: str) -> str | None:
    return _SESSIONS.get(jwt)


async def _rpc(client: httpx.AsyncClient, url: str, jwt: str, method: str,
               params: dict | None = None, intent: str | None = None) -> Any:
    for attempt in range(2):
        sid = await _ensure_session(client, url, jwt, intent=intent)
        body = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": method, "params": params or {}}
        resp = await _post(client, url, body, _base_headers(jwt, sid, intent=intent))
        if resp.status_code in (400, 401, 403):
            # Ext-auth uses 400 for schema-violation denies and 403 for
            # everything else. Both arrive as plain-text bodies (not JSON-RPC).
            # Surface the body verbatim so the inspector trace reads cleanly.
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


async def list_tools(client: httpx.AsyncClient, url: str, jwt: str, intent: str | None = None) -> list[dict]:
    result = await _rpc(client, url, jwt, "tools/list", intent=intent)
    return list(result.get("tools", []))


async def call_tool(client: httpx.AsyncClient, url: str, jwt: str, name: str,
                    arguments: dict | None = None, intent: str | None = None) -> dict:
    return await _rpc(client, url, jwt, "tools/call",
                      {"name": name, "arguments": arguments or {}}, intent=intent)


async def list_tools_raw(client: httpx.AsyncClient, url: str) -> list[dict]:
    """Bypass the gateway: connect straight to a URL with no JWT.

    Used by the inspector UI's "raw upstream" panel — what does the rogue MCP
    advertise when nobody's curating? The answer is: 10 tools with the
    poisoned descriptions.
    """
    init = {
        "jsonrpc": "2.0", "id": "1", "method": "initialize",
        "params": {"protocolVersion": _PROTOCOL_VERSION, "capabilities": {},
                   "clientInfo": {"name": "raw-probe", "version": "0.1"}},
    }
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "MCP-Protocol-Version": _PROTOCOL_VERSION}
    r = await client.post(url, content=json.dumps(init), headers=h, timeout=30.0)
    sid = r.headers.get("mcp-session-id") or r.headers.get("Mcp-Session-Id") or ""
    if sid:
        h["Mcp-Session-Id"] = sid
    # MCP spec requires notifications/initialized after initialize.
    notif = {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
    await client.post(url, content=json.dumps(notif), headers=h, timeout=30.0)
    body = {"jsonrpc": "2.0", "id": "2", "method": "tools/list", "params": {}}
    r2 = await client.post(url, content=json.dumps(body), headers=h, timeout=30.0)
    parsed = _parse_response(r2.text)
    if "error" in parsed:
        err = parsed["error"] or {}
        raise MCPError(err.get("code", -32603), err.get("message", "tools/list failed"))
    return list((parsed.get("result") or {}).get("tools", []))
