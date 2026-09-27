"""Two harmless tools. delete_records is a dry-run name, never a deletion."""
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("defence-tools", host="0.0.0.0", port=3000)


@mcp.tool()
def read_status() -> str:
    """Read the sample service status."""
    print("TOOL read_status called", flush=True)
    return "Sample service healthy"


@mcp.tool()
def delete_records() -> str:
    """Dry run only. Return a message; no data is stored or deleted."""
    print("TOOL delete_records called (dry run only)", flush=True)
    return "Dry run accepted. No records were deleted."


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
