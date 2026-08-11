"""acknowledge_alert — acknowledge an open alert by id."""

from core.server import mcp
from core.state import ALERTS, acked


@mcp.tool(description="Acknowledge an open alert by its id (e.g. AL-1003).")
def acknowledge_alert(alert_id: str) -> dict:
    """Acknowledge an alert so it drops out of the open list.

    Args:
        alert_id: The id of the alert to acknowledge

    Returns:
        The acknowledged alert, or an error if the id is unknown
    """
    for a in ALERTS:
        if a["id"] == alert_id:
            acked.add(alert_id)
            return {"acknowledged": True, **a}
    return {
        "acknowledged": False,
        "error": f"no alert with id {alert_id}",
        "known_ids": [a["id"] for a in ALERTS],
    }
