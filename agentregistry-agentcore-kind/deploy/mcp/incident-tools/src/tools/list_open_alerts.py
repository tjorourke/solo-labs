"""list_open_alerts — list the alerts currently open, optionally for one service."""

from core.server import mcp
from core.state import ALERTS, acked


@mcp.tool(description="List open alerts. Optionally filter by service name.")
def list_open_alerts(service: str = "") -> list[dict]:
    """List the alerts currently open.

    Args:
        service: Optional service name to filter by (e.g. "checkout")

    Returns:
        Open (unacknowledged) alerts, each with id, service, severity and summary
    """
    return [
        a for a in ALERTS
        if a["id"] not in acked and (not service or a["service"] == service)
    ]
