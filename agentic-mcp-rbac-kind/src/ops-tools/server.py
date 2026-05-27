"""ops-tools — a tiny MCP server hosting 6 tools at a single /mcp endpoint.

Unlike the hitl-kind lab (which hosted two MCP servers on two paths so the
gateway could gate by path), this lab uses one endpoint with six tools and
relies on the agentgateway's *MCP-aware* authorization layer to filter
tools/list and short-circuit tools/call per-identity. Everything the gateway
needs (the tool name) lives in the JSON-RPC body, but we never inspect it
ourselves — the gateway speaks MCP.

The DB is in-memory; restarts wipe state.
"""
from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

# FastMCP auto-enables DNS rebinding protection when its (unused-here) internal
# `host` setting defaults to 127.0.0.1, which then rejects the in-cluster
# gateway Host header with a 421. We sit behind agentgateway, so disable it.
_TS = TransportSecuritySettings(enable_dns_rebinding_protection=False)


# ─── Mock in-memory state ─────────────────────────────────────────────────────
class MockState:
    def __init__(self) -> None:
        self.orders: list[dict[str, Any]] = [
            {"id": 1, "customer": "acme",    "total": 199.00, "status": "paid"},
            {"id": 2, "customer": "globex",  "total":  42.50, "status": "paid"},
            {"id": 3, "customer": "initech", "total": 1800.00, "status": "pending"},
        ]
        self.customers: list[dict[str, Any]] = [
            {"id": "acme",    "tier": "gold"},
            {"id": "globex",  "tier": "silver"},
            {"id": "initech", "tier": "bronze"},
        ]
        self.schema_version = "v2"
        # Mock secrets store — pretending to be the platform's secrets vault.
        # Only `alice` should ever see these; this lab keeps the server
        # ignorant of identity (the gateway enforces who can call this).
        self.secrets: dict[str, str] = {
            "db.password":     "hunter2-prod-2024",
            "stripe.api_key":  "sk_live_REDACTED_FOR_DEMO_USE_ONLY",
            "github.token":    "ghp_REDACTED_for_demo",
        }
        self.audit: list[dict[str, Any]] = [
            {"ts": "2026-05-21T09:14:02Z", "actor": "platform-bot", "op": "deploy", "target": "orders-svc@v1.4.2"},
            {"ts": "2026-05-21T11:07:48Z", "actor": "alice",        "op": "rotate-key", "target": "db.password"},
            {"ts": "2026-05-22T03:33:21Z", "actor": "platform-bot", "op": "migrate", "target": "v1→v2"},
        ]

    def now(self) -> str:
        return datetime.now(timezone.utc).isoformat()


state = MockState()


# ─── Single FastMCP server with 6 tools ──────────────────────────────────────
mcp = FastMCP("ops-tools", stateless_http=True, transport_security=_TS)


@mcp.tool()
def read_orders(limit: int = 10) -> dict:
    """Return up to `limit` rows from the orders table."""
    rows = state.orders[: max(0, int(limit))]
    return {"rows": rows, "schema_version": state.schema_version}


@mcp.tool()
def read_customers(limit: int = 10) -> dict:
    """Return up to `limit` rows from the customers table."""
    rows = state.customers[: max(0, int(limit))]
    return {"rows": rows, "schema_version": state.schema_version}


@mcp.tool()
def truncate_table(table: str) -> dict:
    """Empty all rows from a table (destructive)."""
    if table == "orders":
        n = len(state.orders); state.orders = []
    elif table == "customers":
        n = len(state.customers); state.customers = []
    else:
        raise ValueError(f"unknown table {table!r}; valid: ['orders', 'customers']")
    state.audit.append({"ts": state.now(), "actor": "agent", "op": "truncate", "target": table, "rows": n})
    return {"truncated": table, "rows_deleted": n}


@mcp.tool()
def run_migration(version: str) -> dict:
    """Apply a mock schema migration."""
    valid = {"v1", "v2", "v3", "v4"}
    if version not in valid:
        raise ValueError(f"unknown migration version {version!r}; valid: {sorted(valid)}")
    prev = state.schema_version
    state.schema_version = version
    state.audit.append({"ts": state.now(), "actor": "agent", "op": "migrate", "from": prev, "to": version})
    return {"migrated": True, "from": prev, "to": version}


@mcp.tool()
def get_secrets(key: str) -> dict:
    """Return the value of a platform secret. Should be admin-only."""
    if key not in state.secrets:
        raise ValueError(f"unknown secret {key!r}; available keys: {sorted(state.secrets)}")
    state.audit.append({"ts": state.now(), "actor": "agent", "op": "get_secrets", "target": key})
    return {"key": key, "value": state.secrets[key]}


@mcp.tool()
def audit_log(since: str = "") -> dict:
    """Return audit log entries (ISO timestamps, oldest first).

    `since` is an optional ISO timestamp; only entries strictly newer are
    returned. Empty string returns the full log.
    """
    if not since:
        return {"entries": list(state.audit)}
    return {"entries": [e for e in state.audit if e.get("ts", "") > since]}


# ─── Small introspection endpoints (not MCP, just for the runbook) ────────────
async def health(_request):
    return JSONResponse({"status": "ok", "schema_version": state.schema_version})


async def state_endpoint(_request):
    return JSONResponse(
        {
            "schema_version": state.schema_version,
            "row_counts": {"orders": len(state.orders), "customers": len(state.customers)},
            "audit": state.audit[-20:],
            "secret_keys": sorted(state.secrets.keys()),
        }
    )


# ─── Starlette router ─────────────────────────────────────────────────────────
import contextlib


@contextlib.asynccontextmanager
async def lifespan(_app):
    async with contextlib.AsyncExitStack() as stack:
        await stack.enter_async_context(mcp.session_manager.run())
        yield


# FastMCP's streamable_http_app exposes the MCP endpoint at /mcp internally.
# Mounting it under /mcp would put the real endpoint at /mcp/mcp — and a POST
# to bare /mcp would 307-redirect to /mcp/ with the UPSTREAM's DNS in the
# Location header (Starlette uses Host), letting the client bypass the
# gateway entirely. Mount at "/" instead; the named Routes for /healthz +
# /state are evaluated first and the Mount catches everything else.
app = Starlette(
    routes=[
        Route("/healthz", health),
        Route("/state", state_endpoint),
        Mount("/", app=mcp.streamable_http_app()),
    ],
    lifespan=lifespan,
)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        log_level=os.environ.get("LOG_LEVEL", "info"),
    )
