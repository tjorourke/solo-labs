"""
guard-adapter — agentgateway Custom Guardrails Webhook backed by an EXTERNAL
guardrail service.

This is the bridge in the lab. It speaks two contracts:

  1. INBOUND — the Solo agentgateway GuardRail Webhook API v0.1.0:
       POST /request   PromptMessages  in → Pass | Mask | Reject
       POST /response  ResponseChoices in → Pass | Mask
     (identical wire types to the agentic-pii-guardrail-kind webhook — that
      lab proved this shape against agentgateway.)

  2. OUTBOUND — an external content-firewall "evaluate" endpoint:
       POST $GUARD_URL  { "input", "phase", "metadata" } → verdict
     In the lab this is the local `trustguard-stub`. In real mode it is the
     NeuralTrust GAF "API Engine" endpoint — set GUARD_URL + GUARD_API_KEY and,
     if the field names differ, adjust ONLY `_call_guard` below.

The adapter never inspects content itself. agentgateway hands it a normalised,
provider-agnostic message/choice payload regardless of which LLM backend the
route points at — so the SAME external guardrail protects an OpenAI route, a
Gemini route, or an Anthropic route with no per-provider config. That is the
"guardrail decoupled from the backend LLM" point the lab demonstrates.

/events records, for every decision, the RAW inbound body agentgateway sent.
That capture is the evidence that the webhook payload carries messages/choices
only — no model, no provider — which is the concrete gap in the upstream RFE.
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from collections import deque
from threading import Lock
from typing import Any, Literal

import httpx
from fastapi import FastAPI, Request
from pydantic import BaseModel, Field

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("guard-adapter")

EVENT_BUFFER_SIZE = int(os.getenv("EVENT_BUFFER_SIZE", "200"))

# Outbound guardrail service. Stub by default; real NeuralTrust = URL + key swap.
GUARD_URL = os.getenv("GUARD_URL", "http://trustguard-stub.extguard-demo.svc:8080/v1/guard")
GUARD_API_KEY = os.getenv("GUARD_API_KEY", "")
GUARD_MODE = os.getenv("GUARD_MODE", "stub")  # label only; surfaced in /events
GUARD_TIMEOUT = float(os.getenv("GUARD_TIMEOUT", "10"))
# Fail-open (allow on guard error) or fail-closed (reject). Default closed.
GUARD_FAIL_OPEN = os.getenv("GUARD_FAIL_OPEN", "false").lower() == "true"


# ── Inbound webhook wire types (mirror the AGW GuardRail Webhook API 0.1.0) ───
class Message(BaseModel):
    role: str
    content: str


class PromptMessages(BaseModel):
    messages: list[Message]


class ResponseChoiceMessage(BaseModel):
    message: Message


class ResponseChoices(BaseModel):
    choices: list[ResponseChoiceMessage]


class GuardrailsPromptRequest(BaseModel):
    body: PromptMessages


class GuardrailsResponseRequest(BaseModel):
    body: ResponseChoices


class PassAction(BaseModel):
    reason: str | None = None


class MaskAction(BaseModel):
    body: PromptMessages | ResponseChoices
    reason: str | None = None


class RejectAction(BaseModel):
    body: str
    status_code: int
    reason: str | None = None


class GuardrailsPromptResponse(BaseModel):
    action: PassAction | MaskAction | RejectAction


class GuardrailsResponseResponse(BaseModel):
    action: PassAction | MaskAction


# ── Audit ring (consumed by capture-payload.sh / any inspector) ───────────────
class AuditEntry(BaseModel):
    id: str
    ts: float
    phase: Literal["request", "response"]
    action: Literal["pass", "mask", "reject"]
    guard_mode: str
    raw_inbound: dict[str, Any]      # exactly what agentgateway POSTed to us
    forwarded_inputs: list[str]      # what we sent to the external guard
    categories: list[str] = Field(default_factory=list)
    reason: str | None = None


_events: deque[AuditEntry] = deque(maxlen=EVENT_BUFFER_SIZE)
_events_lock = Lock()


def _record(entry: AuditEntry) -> None:
    with _events_lock:
        _events.append(entry)
    log.info(
        "phase=%s action=%s categories=%s reason=%s",
        entry.phase, entry.action, entry.categories, entry.reason,
    )


# ── The one swap point for real NeuralTrust ───────────────────────────────────
def _call_guard(text: str, phase: str) -> dict[str, Any]:
    """POST one piece of text to the external guardrail and return its verdict.

    Stub/NeuralTrust-API-Engine shape:
      response = { verdict: allow|flag|block, sanitized: str|null, categories: [...] }

    If the real provider uses different field names, map them to that shape
    here — nothing else in the adapter needs to change.
    """
    headers = {"Content-Type": "application/json"}
    if GUARD_API_KEY:
        headers["Authorization"] = f"Bearer {GUARD_API_KEY}"
    payload = {"input": text, "phase": phase, "metadata": {"source": "agentgateway-webhook"}}
    try:
        with httpx.Client(timeout=GUARD_TIMEOUT) as client:
            r = client.post(GUARD_URL, headers=headers, json=payload)
            r.raise_for_status()
            return r.json()
    except Exception as exc:  # noqa: BLE001 — surface any guard failure as a decision
        log.warning("guard call failed: %s (fail_open=%s)", exc, GUARD_FAIL_OPEN)
        if GUARD_FAIL_OPEN:
            return {"verdict": "allow", "categories": ["guard_error"], "sanitized": None}
        return {"verdict": "block", "categories": ["guard_error"], "sanitized": None}


app = FastAPI(
    title="guard-adapter",
    version="0.1.0",
    description="agentgateway Custom Guardrails Webhook → external guardrail (NeuralTrust GAF).",
)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "guard_mode": GUARD_MODE, "guard_url": GUARD_URL}


@app.post("/request", response_model=GuardrailsPromptResponse)
async def process_request(req: GuardrailsPromptRequest, request: Request) -> GuardrailsPromptResponse:
    eid = uuid.uuid4().hex[:12]
    ts = time.time()
    raw = json.loads((await request.body()) or b"{}")
    original = req.body.messages

    forwarded: list[str] = []
    all_categories: list[str] = []
    redacted: list[Message] = []
    any_mask = False

    for msg in original:
        if msg.role not in ("user", "system"):
            redacted.append(msg)
            continue
        forwarded.append(msg.content)
        verdict = _call_guard(msg.content, "request")
        cats = verdict.get("categories", []) or []
        all_categories.extend(cats)

        if verdict.get("verdict") == "block":
            reason = f"external guard blocked: {', '.join(cats) or 'policy violation'}"
            _record(AuditEntry(
                id=eid, ts=ts, phase="request", action="reject", guard_mode=GUARD_MODE,
                raw_inbound=raw, forwarded_inputs=forwarded,
                categories=sorted(set(all_categories)), reason=reason,
            ))
            return GuardrailsPromptResponse(action=RejectAction(
                body="Request blocked by external guardrail (NeuralTrust GAF).",
                status_code=403, reason=reason,
            ))

        sanitized = verdict.get("sanitized")
        if verdict.get("verdict") == "flag" and sanitized is not None:
            any_mask = True
            redacted.append(Message(role=msg.role, content=sanitized))
        else:
            redacted.append(msg)

    if any_mask:
        reason = f"external guard masked: {', '.join(sorted(set(all_categories)))}"
        _record(AuditEntry(
            id=eid, ts=ts, phase="request", action="mask", guard_mode=GUARD_MODE,
            raw_inbound=raw, forwarded_inputs=forwarded,
            categories=sorted(set(all_categories)), reason=reason,
        ))
        return GuardrailsPromptResponse(action=MaskAction(
            body=PromptMessages(messages=redacted), reason=reason,
        ))

    _record(AuditEntry(
        id=eid, ts=ts, phase="request", action="pass", guard_mode=GUARD_MODE,
        raw_inbound=raw, forwarded_inputs=forwarded, categories=[], reason=None,
    ))
    return GuardrailsPromptResponse(action=PassAction(reason="external guard: allow"))


@app.post("/response", response_model=GuardrailsResponseResponse)
async def process_response(req: GuardrailsResponseRequest, request: Request) -> GuardrailsResponseResponse:
    eid = uuid.uuid4().hex[:12]
    ts = time.time()
    raw = json.loads((await request.body()) or b"{}")

    forwarded: list[str] = []
    all_categories: list[str] = []
    redacted_choices: list[ResponseChoiceMessage] = []
    any_mask = False

    for c in req.body.choices:
        forwarded.append(c.message.content)
        verdict = _call_guard(c.message.content, "response")
        cats = verdict.get("categories", []) or []
        all_categories.extend(cats)
        sanitized = verdict.get("sanitized")
        # Response phase supports Pass | Mask only. A "block" verdict on the way
        # back is enforced as a mask of the offending content.
        if verdict.get("verdict") in ("flag", "block") and sanitized is not None:
            any_mask = True
            redacted_choices.append(ResponseChoiceMessage(
                message=Message(role=c.message.role, content=sanitized)))
        elif verdict.get("verdict") == "block":
            any_mask = True
            redacted_choices.append(ResponseChoiceMessage(
                message=Message(role=c.message.role,
                                content="[response withheld by external guardrail]")))
        else:
            redacted_choices.append(c)

    if any_mask:
        reason = f"external guard masked response: {', '.join(sorted(set(all_categories)))}"
        _record(AuditEntry(
            id=eid, ts=ts, phase="response", action="mask", guard_mode=GUARD_MODE,
            raw_inbound=raw, forwarded_inputs=forwarded,
            categories=sorted(set(all_categories)), reason=reason,
        ))
        return GuardrailsResponseResponse(action=MaskAction(
            body=ResponseChoices(choices=redacted_choices), reason=reason,
        ))

    _record(AuditEntry(
        id=eid, ts=ts, phase="response", action="pass", guard_mode=GUARD_MODE,
        raw_inbound=raw, forwarded_inputs=forwarded, categories=[], reason=None,
    ))
    return GuardrailsResponseResponse(action=PassAction(reason="external guard: allow"))


@app.get("/events")
def get_events(limit: int = 50) -> list[AuditEntry]:
    with _events_lock:
        items = list(_events)
    items.reverse()
    return items[:limit]
