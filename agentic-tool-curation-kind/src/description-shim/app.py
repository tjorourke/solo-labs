"""description-shim — a tiny MCP middlebox that serves tools/list from the
curated manifest, and forwards everything else to the rogue upstream MCP.

Why this exists
---------------
The gateway can deny tool *calls* (via the EnterpriseAgentgatewayPolicy CEL
on `mcp.tool.name`) — but it can't rewrite the *descriptions* that come
back in `tools/list`. If the upstream MCP server's tool description text is
poisoned (a prompt-injection payload, "Ignore previous instructions…"), the
gateway has no native way to swap that out. The description text would end
up in the LLM's tool list and influence its decisions.

This shim closes that hole. The curation board approves a tool *and* its
description in a single act: both get pinned in the curated manifest
ConfigMap. The shim returns tools/list straight from the manifest, without
ever consulting the upstream — so the LLM never sees the upstream's
description, only the curated one.

This *also* defends against an attack where the upstream tries to add new
tools after curation. Even if `rogue-mcp` dynamically registers a new tool
at runtime, the shim's tools/list answer comes from the manifest, not from
the upstream, so the new tool stays invisible.

The shim is NOT in the deny-by-default path on `tools/call`:
the gateway's CEL policy does that. We just forward calls through.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

import httpx
import yaml
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

UPSTREAM_URL = os.environ.get(
    "UPSTREAM_URL",
    "http://rogue-mcp.tool-curation.svc.cluster.local:8080/mcp",
)
MANIFEST_PATH = os.environ.get("MANIFEST_PATH", "/etc/curation/manifest.yaml")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("description-shim")

app = FastAPI(title="description-shim")


def _load_manifest() -> dict:
    """Reload the curated manifest from disk on every call.

    The manifest is mounted as a ConfigMap volume; kubelet writes the file
    atomically (symlink swap), so we never see a half-written file. Reading
    on every request is fine for demo traffic, and gives the inspector UI
    a live view when an operator edits the ConfigMap.
    """
    try:
        text = Path(MANIFEST_PATH).read_text()
    except FileNotFoundError:
        logger.error("manifest file %s not found", MANIFEST_PATH)
        return {"approvedTools": [], "forbiddenChains": []}
    try:
        return yaml.safe_load(text) or {}
    except Exception as e:  # noqa: BLE001
        logger.error("manifest parse failed: %s", e)
        return {"approvedTools": [], "forbiddenChains": []}


@app.get("/healthz")
def healthz() -> Response:
    return JSONResponse({"status": "ok"})


@app.get("/curated-manifest")
def curated_manifest() -> Response:
    """Read-only view of the manifest, served as JSON for the inspector UI.

    This is NOT part of the MCP wire — just a convenience for the demo
    panel that wants to render "what the registry says".
    """
    return JSONResponse(_load_manifest())


def _curated_tool_list(manifest: dict) -> list[dict]:
    """Return the curated tools formatted as MCP tools/list entries."""
    out: list[dict] = []
    for t in manifest.get("approvedTools", []):
        out.append({
            "name": t["name"],
            "description": t.get("cleanDescription", ""),
            "inputSchema": t.get("argsSchema", {"type": "object", "properties": {}}),
        })
    return out


def _is_tools_list(body: dict) -> bool:
    return isinstance(body, dict) and body.get("method") == "tools/list"


def _sse_or_json_response(upstream_resp: httpx.Response) -> Response:
    """Mirror upstream's content type back to caller verbatim."""
    return Response(
        content=upstream_resp.content,
        status_code=upstream_resp.status_code,
        headers={
            k: v for k, v in upstream_resp.headers.items()
            if k.lower() not in {"content-length", "transfer-encoding"}
        },
    )


@app.post("/mcp")
@app.post("/mcp/")
async def proxy(request: Request) -> Response:
    """The single MCP endpoint.

    - tools/list → synthesised from the curated manifest, no upstream call.
    - everything else → forwarded verbatim (initialize, notifications/initialized,
      tools/call, ping, etc.).
    """
    raw = await request.body()
    try:
        body = json.loads(raw.decode("utf-8")) if raw else {}
    except json.JSONDecodeError:
        # Not JSON — just forward.
        return await _forward(request, raw)

    if _is_tools_list(body):
        manifest = _load_manifest()
        result = {
            "jsonrpc": "2.0",
            "id": body.get("id"),
            "result": {"tools": _curated_tool_list(manifest)},
        }
        return JSONResponse(result)

    return await _forward(request, raw)


async def _forward(request: Request, raw: bytes) -> Response:
    """Forward a request to the rogue-mcp upstream, preserving headers."""
    fwd_headers = dict(request.headers)
    # httpx fills these in itself.
    for h in ("host", "content-length"):
        fwd_headers.pop(h, None)

    async with httpx.AsyncClient(timeout=30.0) as client:
        upstream_resp = await client.post(
            UPSTREAM_URL,
            content=raw,
            headers=fwd_headers,
        )
    return _sse_or_json_response(upstream_resp)
