"""Users MCP server with get_users, delete_user and wipe_users tools.

The server has no approval or access logic. At the gateway, native MCP
authorization on the users-mcp backend allows get_users and delete_user and
hides wipe_users. hitl-extauth parks delete_user for a reviewer, from the
users-mcp block of its ConfigMap. The server only receives calls the gateway
forwards.
"""
from __future__ import annotations

import contextlib
import os
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


class MockUsers:
    def __init__(self) -> None:
        self.users: list[dict[str, Any]] = [
            {"id": "u-1", "name": "Priya Shah", "email": "priya.shah@example.com"},
            {"id": "u-2", "name": "Tom Reyes", "email": "tom.reyes@example.com"},
            {"id": "u-3", "name": "Aisha Bello", "email": "aisha.bello@example.com"},
        ]
        self.audit: list[dict[str, Any]] = []


db = MockUsers()

mcp = FastMCP("users-mcp", stateless_http=True, transport_security=_TS)


@mcp.tool()
def get_users() -> dict:
    """List users. Needs no approval."""
    return {"users": db.users}


@mcp.tool()
def delete_user(id: str) -> dict:
    """Permanently delete a user by id.

    This server does not check who is calling, or ask for confirmation
    itself. agentgateway in front of it (MCP authorization, then the
    approval gate) decides whether this call ever reaches here.
    """
    match = next((u for u in db.users if u["id"] == id), None)
    if match is None:
        raise ValueError("no such user: %r" % id)
    db.users.remove(match)
    db.audit.append({"op": "delete", "id": id, "name": match["name"]})
    return {"deleted": id, "name": match["name"]}


@mcp.tool()
def wipe_users() -> dict:
    """Delete every user.

    This tool exists so the lab can show native MCP authorization at work:
    the gateway leaves it out of tools/list and refuses calls to it, so a
    call should never reach here.
    """
    removed = len(db.users)
    db.audit.append({"op": "wipe", "count": removed})
    db.users.clear()
    return {"deleted": removed}


async def health(_request):
    return JSONResponse({"status": "ok", "user_count": len(db.users)})


async def state(_request):
    return JSONResponse({"users": db.users, "audit": db.audit[-20:]})


# FastMCP's streamable-HTTP app owns a session manager whose `run()` async
# context must be active before any request is handled. Mounting the sub-app
# into a parent Starlette does not invoke the sub-app's own lifespan, so it
# has to be threaded through the parent's lifespan explicitly.
@contextlib.asynccontextmanager
async def lifespan(_app):
    async with contextlib.AsyncExitStack() as stack:
        await stack.enter_async_context(mcp.session_manager.run())
        yield


app = Starlette(
    routes=[
        Route("/healthz", health),
        Route("/state", state),
        # FastMCP's streamable_http_app() already serves its own "/mcp" path
        # internally, so it's mounted at root here; the effective URL is just
        # "/mcp", not "/mcp/mcp".
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
