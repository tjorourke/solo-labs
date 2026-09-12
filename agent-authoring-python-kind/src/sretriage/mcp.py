"""Create MCP toolsets from the remote server URLs in MCP_SERVERS_CONFIG."""

import json
import os

from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset, StreamableHTTPConnectionParams

# A first connection through a gateway can take longer than the library default.
CONNECT_TIMEOUT_SECONDS = 60


def toolsets() -> list[MCPToolset]:
    """One MCPToolset per remote server named in MCP_SERVERS_CONFIG."""
    servers = json.loads(os.environ.get("MCP_SERVERS_CONFIG", "[]"))
    return [
        MCPToolset(
            connection_params=StreamableHTTPConnectionParams(
                url=server["url"], timeout=CONNECT_TIMEOUT_SECONDS
            )
        )
        for server in servers
        if server.get("type") == "remote"
    ]
