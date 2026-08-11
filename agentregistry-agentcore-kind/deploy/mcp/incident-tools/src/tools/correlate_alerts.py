"""correlate_alerts — group open alerts into probable incidents by service."""

from core.server import mcp
from core.state import ALERTS, acked


@mcp.tool(
    description="Correlate open alerts into probable incidents, grouped by service."
)
def correlate_alerts() -> list[dict]:
    """Group open alerts by service into candidate incidents.

    Returns:
        One entry per service with open alerts: the service, the highest
        severity seen, the alert ids grouped under it, and a suggested title
    """
    groups: dict[str, list[dict]] = {}
    for a in ALERTS:
        if a["id"] in acked:
            continue
        groups.setdefault(a["service"], []).append(a)

    rank = {"critical": 3, "warning": 2, "info": 1}
    incidents = []
    for service, alerts in groups.items():
        top = max(alerts, key=lambda a: rank[a["severity"]])
        incidents.append({
            "service": service,
            "severity": top["severity"],
            "alert_ids": [a["id"] for a in alerts],
            "suggested_title": f"{service}: {top['summary']}",
        })
    return incidents
