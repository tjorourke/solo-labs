"""ops-tools — a tiny MCP server with a mock orders DB.

Hosts two separate MCP servers on one HTTP port so the gateway can gate the
privileged one by URL path without needing JSON-RPC body inspection:

  /public/mcp      — cluster_db_query, truncate_table
  /privileged/mcp  — run_migration

The DB is in-memory; restarts wipe state. The lab is about HITL, not durability.
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

# FastMCP auto-enables DNS rebinding protection when its (unused-here) internal
# `host` setting defaults to 127.0.0.1, which then rejects the in-cluster
# gateway Host header with a 421. We sit behind agentgateway, so disable it.
_TS = TransportSecuritySettings(enable_dns_rebinding_protection=False)


# ─── Mock in-memory DB ────────────────────────────────────────────────────────
class MockDB:
    def __init__(self) -> None:
        self.tables: dict[str, list[dict[str, Any]]] = {
            "orders": [
                {"id": 1, "customer": "acme",    "total": 199.00, "status": "paid"},
                {"id": 2, "customer": "globex",  "total":  42.50, "status": "paid"},
                {"id": 3, "customer": "initech", "total": 1800.00, "status": "pending"},
            ],
            "customers": [
                {"id": "acme",    "tier": "gold"},
                {"id": "globex",  "tier": "silver"},
                {"id": "initech", "tier": "bronze"},
            ],
        }
        self.schema_version = "v2"
        self.audit: list[dict[str, Any]] = []

    def now(self) -> str:
        return datetime.now(timezone.utc).isoformat()


db = MockDB()


# ─── /public — read-only + locally-mutating ───────────────────────────────────
public = FastMCP("ops-tools-public", stateless_http=True, transport_security=_TS)


@public.tool()
def cluster_db_query(sql: str) -> dict:
    """Run a read-only SQL query against the orders DB.

    Supports a deliberately tiny subset of SQL — enough to make the demo
    feel real:
      SELECT * FROM <table>
      SELECT COUNT(*) FROM <table>
    Anything else raises.
    """
    s = sql.strip().rstrip(";").lower()
    if not s.startswith("select"):
        raise ValueError(
            "cluster_db_query is read-only — must start with SELECT "
            "(got %r)" % sql
        )
    if " from " not in s:
        raise ValueError("missing FROM clause in %r" % sql)
    table = s.split(" from ", 1)[1].split()[0]
    if table not in db.tables:
        raise ValueError(
            "unknown table %r; available: %s" % (table, sorted(db.tables))
        )
    if "count(*)" in s:
        return {"rows": [{"count": len(db.tables[table])}], "schema_version": db.schema_version}
    return {"rows": db.tables[table], "schema_version": db.schema_version}


@public.tool()
def truncate_table(table: str) -> dict:
    """Empty all rows from a table.

    This is destructive enough to warrant agent-side HITL (requireApproval in
    the kagent declarative agent). It is NOT gated at the gateway — the
    end-user in the chat is the right approver.
    """
    if table not in db.tables:
        raise ValueError(
            "unknown table %r; available: %s" % (table, sorted(db.tables))
        )
    rows = len(db.tables[table])
    db.tables[table] = []
    db.audit.append({"ts": db.now(), "op": "truncate", "table": table, "rows": rows})
    return {"truncated": table, "rows_deleted": rows}


# ─── /privileged — gated by the gateway ──────────────────────────────────────
privileged = FastMCP("ops-tools-privileged", stateless_http=True, transport_security=_TS)


@privileged.tool()
def run_migration(version: str) -> dict:
    """Apply a schema migration to the orders DB.

    This tool is reachable only through the agentgateway /privileged route,
    which has an extAuth policy that parks every call until a platform
    reviewer approves it.
    """
    valid = {"v1", "v2", "v3", "v4"}
    if version not in valid:
        raise ValueError(
            "unknown migration version %r; valid: %s" % (version, sorted(valid))
        )
    prev = db.schema_version
    db.schema_version = version
    db.audit.append(
        {"ts": db.now(), "op": "migrate", "from": prev, "to": version}
    )
    return {"migrated": True, "from": prev, "to": version}


# ─── Small introspection endpoints (not MCP, just for the runbook) ────────────
async def health(_request):
    return JSONResponse({"status": "ok", "schema_version": db.schema_version})


async def state(_request):
    return JSONResponse(
        {
            "schema_version": db.schema_version,
            "row_counts": {t: len(rows) for t, rows in db.tables.items()},
            "audit": db.audit[-20:],
        }
    )


# ─── Starlette router ─────────────────────────────────────────────────────────
# FastMCP's streamable-HTTP app owns a session manager whose `run()` async
# context must be active before any request is handled. When you mount the
# sub-app into a parent Starlette, the sub-app's own lifespan is NOT invoked —
# you have to thread it through the parent's lifespan yourself.
@contextlib.asynccontextmanager
async def lifespan(_app):
    async with contextlib.AsyncExitStack() as stack:
        await stack.enter_async_context(public.session_manager.run())
        await stack.enter_async_context(privileged.session_manager.run())
        yield


app = Starlette(
    routes=[
        Route("/healthz", health),
        Route("/state", state),
        Mount("/public", app=public.streamable_http_app()),
        Mount("/privileged", app=privileged.streamable_http_app()),
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
