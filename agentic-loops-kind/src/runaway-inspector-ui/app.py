"""runaway-inspector-ui — drives scripted scenarios against the gateway so
the audience can see each runaway-containment counter fire in turn.

Four scenarios:

  S1 · well-behaved        — five distinct tool calls under one goal turn,
                              all succeed within every limit
  S2 · max tool calls cap  — 12 calls in a tight loop, hits
                              max_tool_calls_exceeded around call 11
  S3 · max chain depth     — 6 chained calls with no new turn marker,
                              hits max_chain_depth_exceeded around call 5
  S4 · repetition          — same (tool, args) called 2x — second one
                              denied with repetition_detected

A "Reset session" button wipes the Redis state via the ext-auth admin
endpoint so scenarios are idempotent click-to-click.

The page renders a live counter card after each scenario (tool calls,
turns, chain depth, recent calls) so the audience can correlate the
trace against the limits.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path

import httpx
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import mcp_client

MCP_GATEWAY_URL = os.environ.get(
    "MCP_GATEWAY_URL",
    "http://loops-gateway.agentgateway-system.svc.cluster.local/mcp/",
)
EXTAUTH_ADMIN_URL = os.environ.get(
    "EXTAUTH_ADMIN_URL",
    "http://budget-extauth.runaway-containment.svc.cluster.local:8080",
)
JWT_PATH = os.environ.get("JWT_PATH", "/etc/jwts/agent")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("runaway-inspector-ui")


def _read_jwt() -> str:
    p = Path(JWT_PATH)
    try:
        return p.read_text().strip()
    except FileNotFoundError:
        raise HTTPException(
            status_code=500,
            detail=f"JWT not found at {p}. Check the Deployment mounts the jwt-agent Secret.",
        )


BASE_DIR = Path(__file__).parent
app = FastAPI(title="runaway-inspector-ui")
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

# In-process trace per page-load. The list lives only as long as the pod.
_TRACE: list[dict] = []
_CURRENT_TURN: int = 1


@app.get("/healthz", response_class=PlainTextResponse)
def healthz() -> str:
    return "ok"


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse("index.html", {"request": request})


async def _budget_state() -> dict:
    sid = mcp_client.session_id(_read_jwt())
    if not sid:
        # Initialise a session so /state has something to return.
        async with httpx.AsyncClient() as http:
            try:
                sid = await mcp_client.ensure_session(http, MCP_GATEWAY_URL, _read_jwt())
            except Exception as e:  # noqa: BLE001
                logger.warning("ensure_session failed: %s", e)
                return {"error": str(e)}
    try:
        async with httpx.AsyncClient() as http:
            r = await http.get(f"{EXTAUTH_ADMIN_URL}/state", params={"session": sid}, timeout=5.0)
            r.raise_for_status()
            return r.json()
    except Exception as e:  # noqa: BLE001
        logger.warning("state probe failed: %s", e)
        return {"session": sid, "error": str(e)}


@app.get("/panels", response_class=HTMLResponse)
async def panels(request: Request) -> HTMLResponse:
    state = await _budget_state()
    return templates.TemplateResponse(
        "panels.html",
        {"request": request, "state": state, "trace": _TRACE, "current_turn": _CURRENT_TURN},
    )


@app.post("/reset", response_class=HTMLResponse)
async def reset(request: Request) -> HTMLResponse:
    global _CURRENT_TURN
    _TRACE.clear()
    sid = mcp_client.session_id(_read_jwt())
    if sid:
        try:
            async with httpx.AsyncClient() as http:
                await http.get(f"{EXTAUTH_ADMIN_URL}/reset", params={"session": sid}, timeout=5.0)
        except Exception as e:  # noqa: BLE001
            logger.warning("reset failed: %s", e)
    _CURRENT_TURN = 1
    # We don't drop the cached MCP session — the same session id is re-used
    # so the counters start at 0 again for that session id.
    state = await _budget_state()
    _TRACE.append({"role": "note", "text": "session reset · all counters zeroed"})
    return templates.TemplateResponse(
        "panels.html",
        {"request": request, "state": state, "trace": _TRACE, "current_turn": _CURRENT_TURN},
    )


# ──────────────────────────────────────────────────────────────────────────
# Scenarios
#
# Each one drives a sequence of tools/call requests. We append entries to
# the trace as we go so the audience can see every call + its verdict.
# ──────────────────────────────────────────────────────────────────────────

SCENARIOS = {
    "well_behaved": {
        "label": "S1 · well-behaved task",
        "description": "5 distinct calls across 2 turns; all approved.",
        "calls": [
            ("search",    {"q": "kubernetes pods crashlooping"}),
            ("fetch",     {"url": "https://docs.example.com/kube-debug"}),
            ("calculate", {"expr": "restart_count * 5"}),
            ("summarize", {"text": "Kubelet OOM-killed three pods; node memory exhausted."}),
            ("search",    {"q": "OOM kill remediation"}),
        ],
        # Bump at call 1 (start) and call 4 (refinement). Chain-depth
        # runs of [3, 2] — well under maxChainDepth=4.
        "bump_turn_at_calls": [1, 4],
    },
    "tool_call_cap": {
        "label": "S2 · max tool calls cap",
        "description": "12 calls across 4 turns · trips max_tool_calls_exceeded on call 11.",
        # 12 calls, turn every 3 → chain-depth runs ≤ 3, turns=4 → only
        # tool_calls trips (at call 11).
        "calls": [("search", {"q": f"loop-{i}"}) for i in range(12)],
        "bump_turn_at_calls": [1, 4, 7, 10],
    },
    "chain_depth_cap": {
        "label": "S3 · max chain depth cap",
        "description": "6 chained calls with NO new turn header · trips max_chain_depth_exceeded on call 5.",
        "calls": [
            ("search", {"q": "phase 1"}),
            ("fetch",  {"url": "https://x.example/1"}),
            ("calculate", {"expr": "1+1"}),
            ("search", {"q": "phase 2"}),
            ("fetch",  {"url": "https://x.example/2"}),
            ("summarize", {"text": "all phases"}),
        ],
        "bump_turn_at_calls": [],
    },
    "repetition": {
        "label": "S4 · repetition",
        "description": "search({\"q\":\"same\"}) twice in a row · second one denied with repetition_detected.",
        "calls": [
            ("search", {"q": "same"}),
            ("search", {"q": "same"}),
        ],
        "bump_turn_at_calls": [1],
    },
}


@app.post("/run/{scenario}", response_class=HTMLResponse)
async def run_scenario(request: Request, scenario: str) -> HTMLResponse:
    global _CURRENT_TURN
    if scenario not in SCENARIOS:
        raise HTTPException(404, f"unknown scenario {scenario!r}")
    spec = SCENARIOS[scenario]

    _TRACE.clear()
    _TRACE.append({"role": "scenario", "label": spec["label"], "description": spec["description"]})

    jwt = _read_jwt()
    bump_at = set(spec.get("bump_turn_at_calls", []))
    turn = _CURRENT_TURN

    async with httpx.AsyncClient() as http:
        for i, (tool, args) in enumerate(spec["calls"], start=1):
            use_turn = None
            if i in bump_at:
                turn = turn + 1
                _CURRENT_TURN = turn
                use_turn = turn

            entry = {
                "role": "call",
                "n": i,
                "tool": tool,
                "args_json": json.dumps(args),
                "turn": use_turn,
            }
            try:
                result = await mcp_client.call_tool(
                    http, MCP_GATEWAY_URL, jwt, tool, args, turn=use_turn,
                )
                entry["verdict"] = "allowed"
                entry["result_preview"] = _preview(result)
            except mcp_client.MCPError as e:
                entry["verdict"] = "denied"
                if e.code == 429:
                    # ext-auth deny — body is JSON; render structured.
                    parsed = _try_json(e.message)
                    entry["deny"] = parsed or {"raw": e.message}
                else:
                    entry["deny"] = {"raw": f"{e.code}: {e.message}"}
                _TRACE.append(entry)
                # On a runaway deny, stop the scenario — that's the
                # "controlled cut-off". The agent would see this and stop.
                break
            _TRACE.append(entry)

    state = await _budget_state()
    return templates.TemplateResponse(
        "panels.html",
        {"request": request, "state": state, "trace": _TRACE, "current_turn": _CURRENT_TURN},
    )


def _try_json(text: str) -> dict | None:
    text = text.strip()
    if not text.startswith("{"):
        return None
    try:
        return json.loads(text)
    except Exception:  # noqa: BLE001
        return None


def _preview(result) -> str:
    if isinstance(result, dict):
        content = result.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    return _truncate(c.get("text", ""))
        return _truncate(json.dumps(result))
    return _truncate(str(result))


def _truncate(s: str, n: int = 200) -> str:
    s = str(s)
    return s if len(s) <= n else s[:n] + f"… ({len(s) - n} chars truncated)"
