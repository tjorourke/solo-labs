"""Shared helpers for the code-mode demo clients.

All three clients (show_tools, run_code, ask_llm) talk to the same place: the
agentgateway MCP endpoint, served over Streamable HTTP at $MCP_URL
(default http://localhost:18770/mcp). In code mode the server exposes a single
`run_code` tool whose *description* is the generated TypeScript API — one async
function per petstore operation — and whose input is `{ "code": "<javascript>" }`.
"""

import json
import os
from contextlib import asynccontextmanager

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

MCP_URL = os.environ.get("MCP_URL", "http://localhost:18770/mcp")
RUN_CODE = "run_code"


@asynccontextmanager
async def mcp_session(url: str = MCP_URL):
    """Open an initialized MCP session against the gateway."""
    async with streamablehttp_client(url) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            yield session


def tool_text(result) -> str:
    """Flatten an MCP CallToolResult into plain text."""
    parts = []
    for block in result.content or []:
        text = getattr(block, "text", None)
        if text is not None:
            parts.append(text)
    return "\n".join(parts)


def run_code_payload(result) -> dict:
    """run_code returns {"success": <value>} or {"error": {...}} as JSON text."""
    text = tool_text(result)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text}
