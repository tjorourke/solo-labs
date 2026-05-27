"""
pii-guardrail-webhook — Solo agentgateway Custom Guardrails Webhook.

Implements the GuardRail Webhook API v0.1.0 contract:
  POST /request   - PromptMessages in,  PassAction | MaskAction | RejectAction out
  POST /response  - ResponseChoices in, PassAction | MaskAction out

The built-in regex prompt guards on the EnterpriseAgentgatewayPolicy already
mask the global PII patterns (SSN, CreditCard, Email, PhoneNumber, CaSin).
This webhook layers EU/UK-specific patterns the built-ins don't ship:

  - UK National Insurance Number (NINo)
  - IBAN (any country, 15-34 chars)
  - EU passport (1 letter + 8 digits — common UK/IE/DE shape)

It also Rejects when an obvious prompt-injection pattern shows up.

The /events endpoint (HTTP, not part of the webhook contract) is consumed by
the inspector-ui to render "what the LLM actually saw after redaction".
"""
from __future__ import annotations

import logging
import os
import re
import time
import uuid
from collections import deque
from threading import Lock
from typing import Literal

from fastapi import FastAPI
from pydantic import BaseModel, Field

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("guardrail")

EVENT_BUFFER_SIZE = int(os.getenv("EVENT_BUFFER_SIZE", "100"))

# ── PII patterns the built-ins don't ship ─────────────────────────────────────
# Deliberately permissive shapes, not full validators. The demo sample inputs
# use placeholder values (e.g. "QQ123456C") that aren't valid HMRC-issued
# NINOs, so a stricter regex would refuse to match them. For real workloads,
# tighten these or swap in Microsoft Presidio recognizers behind the same
# /request and /response contract.
PII_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # UK National Insurance Number: 2 letters + 6 digits + 1 letter.
    # Real HMRC NINOs exclude D/F/I/Q/U/V as the first letter and other
    # corner cases, but the demo wants any "QQ123456C"-shaped token to match.
    ("UK_NINO", re.compile(r"\b[A-Z]{2}\d{6}[A-Z]\b")),
    # IBAN: ISO 13616 — 2-letter country, 2 check digits, up to 30 alnum.
    ("IBAN", re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b")),
    # EU/UK passport: one letter + 8 digits. Matches several national formats.
    ("EU_PASSPORT", re.compile(r"\b[A-Z]\d{8}\b")),
]

# Prompt-injection — a tiny illustrative set. Real deployments would use a
# semantic classifier; this is just to show the Reject path.
INJECTION_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"ignore (all|previous|the above) (instructions|rules|prompts)", re.I),
    re.compile(r"disregard (all|previous|the above) (instructions|rules|prompts)", re.I),
    re.compile(r"you are now (a |an )?(.*?)without restrictions", re.I),
    re.compile(r"reveal (your |the )?system prompt", re.I),
]


# ── Webhook wire types (mirror the OpenAPI 0.1.0 spec) ────────────────────────
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


# ── In-memory audit ring (consumed by inspector-ui) ───────────────────────────
class AuditEntry(BaseModel):
    id: str
    ts: float
    phase: Literal["request", "response"]
    action: Literal["pass", "mask", "reject"]
    original: list[Message]
    redacted: list[Message]
    matches: list[str] = Field(default_factory=list)
    reason: str | None = None


_events: deque[AuditEntry] = deque(maxlen=EVENT_BUFFER_SIZE)
_events_lock = Lock()


def _record(entry: AuditEntry) -> None:
    with _events_lock:
        _events.append(entry)
    log.info(
        "phase=%s action=%s matches=%s reason=%s",
        entry.phase, entry.action, entry.matches, entry.reason,
    )


# ── Redaction core ────────────────────────────────────────────────────────────
def _redact_text(text: str) -> tuple[str, list[str]]:
    """Apply each PII pattern in turn, replacing matches with `[<LABEL>]`."""
    matches: list[str] = []
    out = text
    for label, rx in PII_PATTERNS:
        def _sub(_m: re.Match[str], _label: str = label) -> str:
            matches.append(_label)
            return f"[REDACTED:{_label}]"
        out = rx.sub(_sub, out)
    return out, matches


def _check_injection(text: str) -> str | None:
    for rx in INJECTION_PATTERNS:
        m = rx.search(text)
        if m:
            return m.group(0)
    return None


# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="pii-guardrail-webhook",
    version="0.1.0",
    description="Custom Guardrails Webhook — EU/UK PII redaction + injection reject.",
)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/request", response_model=GuardrailsPromptResponse)
def process_request(req: GuardrailsPromptRequest) -> GuardrailsPromptResponse:
    eid = uuid.uuid4().hex[:12]
    ts = time.time()
    original = req.body.messages

    # 1. Reject path — any injection pattern in any user/system message.
    for msg in original:
        if msg.role in ("user", "system"):
            hit = _check_injection(msg.content)
            if hit is not None:
                reason = f"prompt-injection pattern matched: {hit!r}"
                _record(AuditEntry(
                    id=eid, ts=ts, phase="request", action="reject",
                    original=original, redacted=original,
                    matches=["INJECTION"], reason=reason,
                ))
                return GuardrailsPromptResponse(action=RejectAction(
                    body="Request blocked by guardrail webhook: suspected prompt injection.",
                    status_code=403,
                    reason=reason,
                ))

    # 2. Mask path — apply EU/UK PII regexes to every message.
    redacted: list[Message] = []
    all_matches: list[str] = []
    any_change = False
    for msg in original:
        new_content, hits = _redact_text(msg.content)
        if hits:
            any_change = True
            all_matches.extend(hits)
        redacted.append(Message(role=msg.role, content=new_content))

    if any_change:
        _record(AuditEntry(
            id=eid, ts=ts, phase="request", action="mask",
            original=original, redacted=redacted,
            matches=sorted(set(all_matches)),
            reason=f"masked: {', '.join(sorted(set(all_matches)))}",
        ))
        return GuardrailsPromptResponse(action=MaskAction(
            body=PromptMessages(messages=redacted),
            reason=f"masked: {', '.join(sorted(set(all_matches)))}",
        ))

    # 3. Pass path — record the trace anyway so the UI can show "saw it, did nothing".
    _record(AuditEntry(
        id=eid, ts=ts, phase="request", action="pass",
        original=original, redacted=original, matches=[], reason=None,
    ))
    return GuardrailsPromptResponse(action=PassAction(reason="no PII or injection detected"))


@app.post("/response", response_model=GuardrailsResponseResponse)
def process_response(req: GuardrailsResponseRequest) -> GuardrailsResponseResponse:
    eid = uuid.uuid4().hex[:12]
    ts = time.time()
    original_msgs = [c.message for c in req.body.choices]

    redacted_choices: list[ResponseChoiceMessage] = []
    all_matches: list[str] = []
    any_change = False
    for c in req.body.choices:
        new_content, hits = _redact_text(c.message.content)
        if hits:
            any_change = True
            all_matches.extend(hits)
        redacted_choices.append(ResponseChoiceMessage(
            message=Message(role=c.message.role, content=new_content),
        ))

    if any_change:
        _record(AuditEntry(
            id=eid, ts=ts, phase="response", action="mask",
            original=original_msgs,
            redacted=[c.message for c in redacted_choices],
            matches=sorted(set(all_matches)),
            reason=f"masked: {', '.join(sorted(set(all_matches)))}",
        ))
        return GuardrailsResponseResponse(action=MaskAction(
            body=ResponseChoices(choices=redacted_choices),
            reason=f"masked: {', '.join(sorted(set(all_matches)))}",
        ))

    _record(AuditEntry(
        id=eid, ts=ts, phase="response", action="pass",
        original=original_msgs, redacted=original_msgs,
        matches=[], reason=None,
    ))
    return GuardrailsResponseResponse(action=PassAction(reason="no PII detected"))


# ── Admin API (not part of the AGW webhook contract) ──────────────────────────
@app.get("/events")
def get_events(limit: int = 50) -> list[AuditEntry]:
    """Return the most recent decisions, newest first. Used by inspector-ui."""
    with _events_lock:
        items = list(_events)
    items.reverse()
    return items[:limit]


@app.get("/events/{event_id}")
def get_event(event_id: str) -> AuditEntry | dict[str, str]:
    with _events_lock:
        items = list(_events)
    for e in reversed(items):
        if e.id == event_id:
            return e
    return {"error": "not found"}
