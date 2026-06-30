"""
trustguard-stub — a local stand-in for an external guardrail verdict API.

This mimics the *shape* of an external content-firewall "evaluate" endpoint
(NeuralTrust GAF "API Engine", or any similar provider): you POST a piece of
text plus a little context, and it returns an allow / flag / block verdict,
optionally with a sanitized (masked) version of the text.

The whole point of the stub is that the agentgateway guardrail webhook
(`guard-adapter`) calls THIS exactly the way it would call the real service.
Flipping the lab to the real provider is then only a URL + API key change in
the adapter (GUARD_URL / GUARD_API_KEY) plus, if the field names differ,
reconciling the request/response mapping in `guard-adapter/app.py::_call_guard`.

Contract (stub's own — reconcile with the real provider's API reference):

  POST /v1/guard
    Authorization: Bearer <api-key>          # logged but not enforced in stub
    { "input": "<text>", "phase": "request"|"response", "metadata": {...} }

  200 OK
    {
      "verdict": "allow" | "flag" | "block",
      "flagged": bool,
      "categories": ["jailbreak", "pii:UK_NINO", ...],
      "sanitized": "<masked text>" | null,
      "detail": "<human-readable reason>"
    }

GET /received?limit=50  — ring buffer of what the adapter forwarded to us, so
the lab can SHOW that the payload reaching the guard is provider-agnostic
text (no model / provider field). This is the concrete evidence for the
upstream RFE about model/provider not being on the webhook body.
"""
from __future__ import annotations

import logging
import os
import re
import time
import uuid
from collections import deque
from threading import Lock
from typing import Any, Literal

from fastapi import FastAPI, Request
from pydantic import BaseModel

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("trustguard-stub")

RECEIVED_BUFFER_SIZE = int(os.getenv("RECEIVED_BUFFER_SIZE", "200"))

# ── Detectors (illustrative — a real GAF runs semantic classifiers) ───────────
# Jailbreak / prompt-injection → block. PII → flag + mask. Otherwise allow.
INJECTION_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"ignore (all|previous|the above) (instructions|rules|prompts)", re.I),
    re.compile(r"disregard (all|previous|the above) (instructions|rules|prompts)", re.I),
    re.compile(r"you are now (a |an )?(.*?)without restrictions", re.I),
    re.compile(r"reveal (your |the )?system prompt", re.I),
    re.compile(r"\bDAN\b.*(mode|jailbreak)", re.I),
]

PII_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("UK_NINO", re.compile(r"\b[A-Z]{2}\d{6}[A-Z]\b")),
    ("IBAN", re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b")),
    ("EU_PASSPORT", re.compile(r"\b[A-Z]\d{8}\b")),
    ("EMAIL", re.compile(r"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b")),
    ("SSN", re.compile(r"\b\d{3}-\d{2}-\d{4}\b")),
    ("CREDIT_CARD", re.compile(r"\b(?:\d[ -]?){13,16}\b")),
]


class GuardRequest(BaseModel):
    input: str
    phase: Literal["request", "response"] = "request"
    metadata: dict[str, Any] = {}


class GuardResponse(BaseModel):
    verdict: Literal["allow", "flag", "block"]
    flagged: bool
    categories: list[str] = []
    sanitized: str | None = None
    detail: str | None = None


class ReceivedEntry(BaseModel):
    id: str
    ts: float
    phase: str
    input: str
    metadata: dict[str, Any]
    verdict: str
    categories: list[str]


_received: deque[ReceivedEntry] = deque(maxlen=RECEIVED_BUFFER_SIZE)
_lock = Lock()


def _detect(text: str) -> tuple[str, list[str], str | None]:
    """Return (verdict, categories, sanitized_or_None)."""
    for rx in INJECTION_PATTERNS:
        m = rx.search(text)
        if m:
            return "block", ["jailbreak"], None

    categories: list[str] = []
    sanitized = text
    for label, rx in PII_PATTERNS:
        if rx.search(sanitized):
            categories.append(f"pii:{label}")
            sanitized = rx.sub(f"[REDACTED:{label}]", sanitized)

    if categories:
        return "flag", categories, sanitized
    return "allow", [], None


app = FastAPI(
    title="trustguard-stub",
    version="0.1.0",
    description="Local stand-in for an external guardrail verdict API (NeuralTrust GAF API Engine shape).",
)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/guard", response_model=GuardResponse)
async def guard(req: GuardRequest, request: Request) -> GuardResponse:
    verdict, categories, sanitized = _detect(req.input)
    auth = request.headers.get("authorization", "")
    log.info(
        "phase=%s verdict=%s categories=%s auth=%s input=%r",
        req.phase, verdict, categories, "present" if auth else "absent",
        req.input[:120],
    )
    with _lock:
        _received.append(ReceivedEntry(
            id=uuid.uuid4().hex[:12], ts=time.time(), phase=req.phase,
            input=req.input, metadata=req.metadata,
            verdict=verdict, categories=categories,
        ))
    detail = {
        "allow": "no policy violation detected",
        "flag": f"sensitive content detected: {', '.join(categories)}",
        "block": "prompt-injection / jailbreak attempt detected",
    }[verdict]
    return GuardResponse(
        verdict=verdict, flagged=verdict != "allow",
        categories=categories, sanitized=sanitized, detail=detail,
    )


@app.get("/received")
def received(limit: int = 50) -> list[ReceivedEntry]:
    """Most recent payloads the adapter forwarded, newest first."""
    with _lock:
        items = list(_received)
    items.reverse()
    return items[:limit]
