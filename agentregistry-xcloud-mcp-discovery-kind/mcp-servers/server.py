"""Small FastMCP server used as an externally hosted MCP in the lab.

One image, two personalities. CLOUD=cloud-a serves a compute inventory,
CLOUD=cloud-b serves a cost report. The data is fixed so the demo is repeatable.
Tested with fastmcp 4.1.6 (pinned in requirements.txt).
"""
import os

from fastmcp import FastMCP

CLOUD = os.environ.get("CLOUD", "cloud-a")
mcp = FastMCP(f"{CLOUD}-tools")

if CLOUD == "cloud-a":
    INSTANCES = {
        "web-01": {"region": "eu-west", "state": "running"},
        "web-02": {"region": "eu-west", "state": "stopped"},
        "batch-07": {"region": "us-east", "state": "running"},
    }

    @mcp.tool
    def list_instances(region: str = "") -> list[dict]:
        """List compute instances in cloud-a, optionally for one region."""
        return [
            {"name": n, **v}
            for n, v in INSTANCES.items()
            if not region or v["region"] == region
        ]

    @mcp.tool
    def get_instance(name: str) -> dict:
        """Return the region and state of one cloud-a instance."""
        return {"name": name, **INSTANCES.get(name, {"state": "unknown"})}

    @mcp.tool
    def restart_instance(name: str) -> str:
        """Restart a cloud-a instance. The platform team hides this from developers."""
        return f"restart requested for {name}"

else:
    SPEND = {"2026-09": 41210.55, "2026-10": 43877.10}

    @mcp.tool
    def monthly_spend(month: str) -> dict:
        """Return cloud-b spend in GBP for a month such as 2026-10."""
        return {"month": month, "gbp": SPEND.get(month)}

    @mcp.tool
    def top_services(limit: int = 3) -> list[dict]:
        """Return the most expensive cloud-b services last month."""
        rows = [
            {"service": "managed-postgres", "gbp": 12100.00},
            {"service": "object-storage", "gbp": 9050.20},
            {"service": "gpu-nodes", "gbp": 8400.75},
            {"service": "egress", "gbp": 3120.00},
        ]
        return rows[:limit]


if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000, path="/mcp")
