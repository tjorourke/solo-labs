"""MCP servers, from the environment.

kagent hands the agent its approved tool servers in MCP_SERVERS_CONFIG, a JSON list of
{"name", "type", "url"}. The URL is the agentgateway waypoint, so the credential, the
tool filtering and the identity policy all live there. The agent reads the list; it
does not choose, and it holds no credential of its own.
"""

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
