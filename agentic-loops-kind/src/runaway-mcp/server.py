"""runaway-mcp — a tiny MCP server with four cheap tools.

This server's job is to NOT be the interesting part. The lab is about how
the gateway + ext-auth count tool calls, turns, chain depth, and detect
repetition — so the tools themselves are deliberately trivial:

  - search(q)         — canned "results"
  - fetch(url)        — canned "body"
  - calculate(expr)   — canned "result" (no real eval)
  - summarize(text)   — canned "summary"

Each returns a small JSON object that includes `tokens_used` — a fake
counter that mimics what a real LLM-call-through-the-gateway would report.
The lab doesn't enforce token limits at this layer (the sibling
agentic-budgets-kind covers that); we surface tokens_used for
demonstration only.
"""
from __future__ import annotations

import os
from datetime import datetime, timezone

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route


_TS = TransportSecuritySettings(enable_dns_rebinding_protection=False)
_NOW = lambda: datetime.now(timezone.utc).isoformat()  # noqa: E731


mcp = FastMCP("runaway-mcp", stateless_http=True, transport_security=_TS)


@mcp.tool()
def search(q: str = "") -> dict:
    """Search for a term. Returns a canned list of result titles."""
    return {
        "query": q,
        "results": [
            f"Result 1 for '{q}'",
            f"Result 2 for '{q}'",
            f"Result 3 for '{q}'",
        ],
        "tokens_used": 120,
        "fetched_at": _NOW(),
    }


@mcp.tool()
def fetch(url: str = "") -> dict:
    """Fetch the body of a URL. We don't actually fetch — returns canned bytes."""
    return {
        "url": url,
        "status": 200,
        "body_preview": "<canned-body-truncated>",
        "tokens_used": 200,
        "fetched_at": _NOW(),
    }


@mcp.tool()
def calculate(expr: str = "0") -> dict:
    """Evaluate a math expression. Returns a canned numeric result.

    We deliberately don't run eval() — the demo's about the gateway's loop
    counters, not arithmetic.
    """
    return {
        "expr": expr,
        "result": 42,
        "tokens_used": 80,
        "fetched_at": _NOW(),
    }


@mcp.tool()
def summarize(text: str = "") -> dict:
    """Summarise a chunk of text. Returns a canned one-line summary."""
    head = (text or "")[:40]
    return {
        "input_preview": head,
        "summary": "A short summary of the input text.",
        "tokens_used": 160,
        "fetched_at": _NOW(),
    }


# ─── introspection ──────────────────────────────────────────────────────────
async def health(_request):
    return JSONResponse({"status": "ok"})


# ─── Starlette router ───────────────────────────────────────────────────────
import contextlib


@contextlib.asynccontextmanager
async def lifespan(_app):
    async with contextlib.AsyncExitStack() as stack:
        await stack.enter_async_context(mcp.session_manager.run())
        yield


app = Starlette(
    routes=[
        Route("/healthz", health),
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
