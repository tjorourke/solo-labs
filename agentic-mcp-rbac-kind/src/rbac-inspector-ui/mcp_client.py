"""Tiny MCP client over streamable-HTTP JSON-RPC.

This client speaks just enough of MCP to drive the RBAC demo:

  - initialize           (mandatory handshake; the gateway requires the
                          session and stamps `Mcp-Session-Id` on the response)
  - notifications/initialized (the MCP spec's "I'm ready" note — required
                          before any non-initialize request)
  - tools/list           (filtered per-identity by the gateway)
  - tools/call           (also filtered — denied tools come back as
                          JSON-RPC -32602)

We deliberately do NOT use the upstream Python `mcp` SDK here. That SDK
maintains a persistent session, manages an event-loop-bound transport, and
expects long-lived process state — none of which lines up with this UI's
"each user request is a fresh round-trip with a possibly-different JWT"
shape. A direct httpx POST is much simpler and easier to reason about for
the demo.

## Sessions

The Solo Enterprise agentgateway, when configured as an MCP backend
(`AgentgatewayBackend.spec.mcp`), enforces the streamable-HTTP session
protocol from the spec: the client MUST `initialize` first, capture the
`Mcp-Session-Id` header from the response, send `notifications/initialized`
(JSON-RPC notification, no `id`), and then include `Mcp-Session-Id` on every
subsequent `tools/list` / `tools/call`. Skipping any of those returns a
plain-text error: `mcp: session header is required for non-initialize
requests`.

Bare FastMCP in stateless mode is laxer — it accepts non-initialize requests
without a session — so an earlier version of this client could skip the
handshake. Going through the gateway tightens that.

We do one initialize per outbound JWT (each identity has its own session).
Sessions are cached in-process by JWT. If the gateway expires a session
(401 / "session header required"), we transparently re-initialize once and
retry.

## Response framing

The streamable-HTTP transport returns either a plain JSON body OR a single
Server-Sent Event (`data: <json>`). We handle both.
"""
from __future__ import annotations

import json
import uuid
from typing import Any

import httpx


class MCPError(Exception):
    """A JSON-RPC error response from the MCP server (or gateway).

    Carries the JSON-RPC error code and message verbatim so the UI can
    surface "gateway said: -32602 Unknown tool" rather than a generic
    HTTP-level failure.
    """

    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(f"{code} {message}")
        self.code = code
        self.message = message
        self.data = data


# Per-JWT session cache: jwt → (mcp_session_id). Single-process; if the UI
# is multi-replica, hoist this to Redis. Demo is single-replica.
_SESSIONS: dict[str, str] = {}

# MCP protocol version we advertise. The gateway echoes this in the
# `MCP-Protocol-Version` response header on initialize; subsequent requests
# include the same value.
_PROTOCOL_VERSION = "2025-03-26"


def _parse_response(text: str) -> dict:
    """Parse either a raw JSON body or an SSE `data:` line into a dict."""
    text = text.strip()
    if not text:
        raise MCPError(-32603, "empty response from MCP server")
    if text.startswith("{"):
        return json.loads(text)
    # SSE framing: pull out the first `data:` line.
    for line in text.splitlines():
        if line.startswith("data:"):
            return json.loads(line[len("data:"):].strip())
    raise MCPError(-32603, f"unrecognized MCP response shape: {text[:120]!r}")


def _base_headers(jwt: str, session_id: str | None = None) -> dict[str, str]:
    h = {
        "Authorization": f"Bearer {jwt}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": _PROTOCOL_VERSION,
    }
    if session_id:
        h["Mcp-Session-Id"] = session_id
    return h


async def _post(
    client: httpx.AsyncClient,
    url: str,
    body: dict,
    headers: dict[str, str],
) -> httpx.Response:
    return await client.post(url, content=json.dumps(body), headers=headers, timeout=30.0)


async def _initialize(client: httpx.AsyncClient, url: str, jwt: str) -> str:
    """Run the MCP handshake and return the `Mcp-Session-Id` to use on
    subsequent calls for this JWT."""
    init_body = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "initialize",
        "params": {
            "protocolVersion": _PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "rbac-inspector-ui", "version": "0.1"},
        },
    }
    resp = await _post(client, url, init_body, _base_headers(jwt))
    if resp.status_code in (401, 403):
        raise MCPError(resp.status_code, f"gateway auth failed at initialize: HTTP {resp.status_code} {resp.text[:200]}")
    if resp.status_code >= 500:
        raise MCPError(-32603, f"upstream HTTP {resp.status_code} on initialize: {resp.text[:200]}")
    # The gateway returns the session id in the Mcp-Session-Id response header
    # per the MCP spec. Some servers also include it in the response body —
    # the header is authoritative.
    session_id = resp.headers.get("mcp-session-id") or resp.headers.get("Mcp-Session-Id")
    parsed = _parse_response(resp.text)
    if "error" in parsed:
        err = parsed["error"] or {}
        raise MCPError(err.get("code", -32603), err.get("message", "initialize failed"), err.get("data"))
    if not session_id:
        # Some MCP backends omit the header but accept calls without one. Use
        # empty string so subsequent calls just don't set the header.
        session_id = ""

    # MCP spec requires a `notifications/initialized` *notification* (no id)
    # before any other request. Skipping it works with some servers; the
    # enterprise agentgateway MCP backend rejects without it.
    notif_body = {
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": {},
    }
    resp2 = await _post(client, url, notif_body, _base_headers(jwt, session_id))
    # Notifications get a 202 Accepted with empty body; we don't parse the
    # response body but we DO surface a hard 5xx so a broken gateway isn't
    # silently glued onto the session.
    if resp2.status_code >= 500:
        raise MCPError(-32603, f"upstream HTTP {resp2.status_code} on notifications/initialized: {resp2.text[:200]}")
    return session_id


async def _ensure_session(client: httpx.AsyncClient, url: str, jwt: str) -> str:
    sid = _SESSIONS.get(jwt)
    if sid is not None:
        return sid
    sid = await _initialize(client, url, jwt)
    _SESSIONS[jwt] = sid
    return sid


def _invalidate(jwt: str) -> None:
    _SESSIONS.pop(jwt, None)


async def _rpc_with_session(
    client: httpx.AsyncClient,
    url: str,
    jwt: str,
    method: str,
    params: dict | None = None,
) -> Any:
    """One JSON-RPC call that may transparently re-initialize on session loss."""
    for attempt in range(2):
        session_id = await _ensure_session(client, url, jwt)
        body = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": method,
            "params": params or {},
        }
        resp = await _post(client, url, body, _base_headers(jwt, session_id))

        # Auth failures: 401 = JWT bad, 403 = JWT good but RBAC denied.
        if resp.status_code in (401, 403):
            raise MCPError(resp.status_code, f"gateway auth failed: HTTP {resp.status_code} {resp.text[:200]}")
        # Session lost (gateway restarted, ttl expired, etc.) — once.
        if resp.status_code in (404, 410) or (
            resp.status_code >= 400 and "session" in resp.text.lower() and attempt == 0
        ):
            _invalidate(jwt)
            continue
        if resp.status_code >= 500:
            raise MCPError(-32603, f"upstream HTTP {resp.status_code}: {resp.text[:200]}")

        parsed = _parse_response(resp.text)
        if "error" in parsed:
            err = parsed["error"] or {}
            raise MCPError(err.get("code", -32603), err.get("message", "unknown"), err.get("data"))
        return parsed.get("result")

    raise MCPError(-32603, "could not establish MCP session after retry")


async def list_tools(client: httpx.AsyncClient, url: str, jwt: str) -> list[dict]:
    """Return the tools the gateway is willing to advertise for this JWT.

    Tools the gateway filters out are simply absent from the result; there is
    no JSON-RPC error in that path — that's "invisible tools" semantics.
    """
    result = await _rpc_with_session(client, url, jwt, "tools/list")
    return list(result.get("tools", []))


async def call_tool(
    client: httpx.AsyncClient,
    url: str,
    jwt: str,
    name: str,
    arguments: dict | None = None,
) -> dict:
    """Invoke a tool. Returns the raw `result` dict (with `content`, etc.).

    On a gateway-denied tool, this raises MCPError(-32602, "Unknown tool").
    """
    return await _rpc_with_session(
        client,
        url,
        jwt,
        "tools/call",
        {"name": name, "arguments": arguments or {}},
    )
