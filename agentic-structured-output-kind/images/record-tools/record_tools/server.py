"""record-tools — a tiny MCP server whose only job is to hold the contract.

The declarative DBA agent is told to answer ONLY by calling record_diagnosis.
The tool's input schema IS the Diagnosis contract (yaml/contract/diagnosis.schema.json),
so the model cannot emit a free-text answer: it must produce the four typed fields.
The tool echoes the validated record straight back, which becomes the agent's result
carried across the A2A hop.

Served over streamable HTTP at /mcp on :8080. kagent reaches it with a
RemoteMCPServer pointing at http://record-tools.kagent.svc.cluster.local:8080/mcp.
"""
from __future__ import annotations

import os
from enum import Enum
from typing import Literal

from mcp.server.fastmcp import FastMCP

# HOST=0.0.0.0 so the container is reachable from the kagent controller, not just
# loopback. Path defaults to /mcp for the streamable-http transport.
mcp = FastMCP(
    "record-tools",
    host=os.environ.get("HOST", "0.0.0.0"),
    port=int(os.environ.get("PORT", "8080")),
)

Severity = Literal["low", "medium", "high", "critical"]


@mcp.tool()
def record_diagnosis(
    root_cause: str,
    severity: Severity,
    fix: str,
    runbook_url: str = "",
) -> dict:
    """Return the database diagnosis. You MUST answer only by calling this tool.

    Args:
        root_cause: What is actually broken, in one or two sentences.
        severity: How bad it is. One of: low, medium, high, critical.
        fix: The exact remediation the on-call should apply.
        runbook_url: Link to the matching runbook, or an empty string if none applies.

    Returns:
        The structured Diagnosis record, echoed back for the caller to carry.
    """
    return {
        "root_cause": root_cause.strip(),
        "severity": severity,
        "fix": fix.strip(),
        "runbook_url": runbook_url.strip(),
    }


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
