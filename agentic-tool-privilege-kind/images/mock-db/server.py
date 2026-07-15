"""mock-db — a simulated Postgres exposed as an MCP server.

No real Postgres is deployed. This process pretends to be the "orders" database
and exposes four tools at a single /mcp endpoint:

  read  : db_status, list_tables, db_query
  write : db_reset_credentials   <- the privileged operation

The incident: the orders DB is locked out (its superuser password was never set),
so logins fail and the app is down. A read-only agent can inspect and DIAGNOSE
this, but only a privileged agent may call db_reset_credentials to FIX it.

The server is deliberately identity-agnostic — it never checks who is calling.
Which agent may call which tool is decided entirely at the agentgateway in front
of it (EnterpriseAgentgatewayPolicy mcp.authorization, keyed on the caller's JWT
group). That is the whole point of the lab: the gateway is the authority, not the
tool server and not the agent.

State is in-memory; a pod restart re-arms the broken incident.
"""
from __future__ import annotations

import contextlib
import os
from datetime import datetime, timezone
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

# We sit behind agentgateway, so disable FastMCP's DNS-rebinding guard (it would
# 421 the gateway's Host header otherwise).
_TS = TransportSecuritySettings(enable_dns_rebinding_protection=False)


class MockDB:
    """A stand-in for the orders Postgres. Starts broken (no superuser password)."""

    def __init__(self) -> None:
        self.name = "orders"
        # locked = the superuser password was never set, so logins fail.
        self.locked = True
        self.password_set = False
        self.tables = {
            "orders": [
                {"id": 1, "customer": "acme", "total": 199.00, "status": "paid"},
                {"id": 2, "customer": "globex", "total": 42.50, "status": "paid"},
                {"id": 3, "customer": "initech", "total": 1800.00, "status": "pending"},
            ],
            "customers": [
                {"id": "acme", "tier": "gold"},
                {"id": "initech", "tier": "bronze"},
            ],
        }
        self.audit: list[dict[str, Any]] = []

    def now(self) -> str:
        return datetime.now(timezone.utc).isoformat()

    def login_error(self) -> str:
        return (
            "FATAL: password authentication failed for user \"orders\" — the "
            "database is uninitialized and the superuser password is not set"
        )


db = MockDB()

mcp = FastMCP("mock-db", stateless_http=True, transport_security=_TS)


# ─── read tools ───────────────────────────────────────────────────────────────
@mcp.tool()
def db_status() -> dict:
    """Report the orders database health: reachable, whether login works, status."""
    healthy = not db.locked
    return {
        "database": db.name,
        "reachable": True,
        "login": "ok" if healthy else db.login_error(),
        "password_set": db.password_set,
        "status": "healthy" if healthy else "degraded",
    }


@mcp.tool()
def list_tables() -> dict:
    """List the tables in the orders database (schema is readable even while locked)."""
    return {"database": db.name, "tables": sorted(db.tables.keys())}


@mcp.tool()
def db_query(table: str, limit: int = 10) -> dict:
    """Run a read-only SELECT against a table. Reads a standby, so it works even
    while the primary is locked — enough to diagnose, not to fix."""
    if table not in db.tables:
        raise ValueError(f"unknown table {table!r}; valid: {sorted(db.tables)}")
    rows = db.tables[table][: max(0, int(limit))]
    return {"table": table, "rows": rows, "note": "read from standby replica"}


# ─── write tool (privileged) ─────────────────────────────────────────────────
@mcp.tool()
def db_reset_credentials(new_password: str) -> dict:
    """Set the orders superuser password and unlock the database (privileged)."""
    if not new_password or len(new_password) < 8:
        raise ValueError("new_password must be at least 8 characters")
    db.locked = False
    db.password_set = True
    db.audit.append({"ts": db.now(), "op": "reset_credentials", "user": "orders"})
    return {
        "database": db.name,
        "status": "healthy",
        "message": "superuser password set; database unlocked and accepting logins",
    }


# ─── introspection (not MCP; for the runbook) ────────────────────────────────
async def health(_request):
    return JSONResponse({"status": "ok"})


async def state_endpoint(_request):
    return JSONResponse(
        {"database": db.name, "locked": db.locked, "password_set": db.password_set, "audit": db.audit[-10:]}
    )


@contextlib.asynccontextmanager
async def lifespan(_app):
    async with contextlib.AsyncExitStack() as stack:
        await stack.enter_async_context(mcp.session_manager.run())
        yield


# Mount the MCP app at "/" so the endpoint is exactly /mcp (see the mcp-rbac
# lab notes: mounting under /mcp causes a 307 that can bypass the gateway).
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

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")),
                log_level=os.environ.get("LOG_LEVEL", "info"))
