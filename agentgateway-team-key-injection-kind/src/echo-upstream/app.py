"""
echo-upstream — a stand-in for the LLM provider (OpenAI-compatible shape).

agentgateway routes a team's request here and injects that team's STATIC upstream
credential. This service reports the `Authorization` and `x-team` it received, so
the lab can prove which key was injected per team — without needing a real
per-team provider account.

It answers the OpenAI chat-completions contract so agentgateway's `ai.provider.openai`
backend parses the reply cleanly: the assistant message simply states what the
upstream saw. A `/seen` ring buffer is the independent source of truth.
"""
from __future__ import annotations

import time
from collections import deque
from threading import Lock

from fastapi import FastAPI, Request

app = FastAPI(title="echo-upstream", version="0.1.0")

_seen: deque[dict[str, object]] = deque(maxlen=100)
_lock = Lock()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/seen")
def seen(limit: int = 20) -> list[dict[str, object]]:
    with _lock:
        items = list(_seen)
    items.reverse()
    return items[:limit]


@app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def echo(full_path: str, request: Request) -> dict[str, object]:
    auth = request.headers.get("authorization", "")
    team = request.headers.get("x-team", "")
    user = request.headers.get("x-user-id", "")
    all_x = {k: v for k, v in request.headers.items() if k.lower().startswith("x-") or k.lower() == "authorization"}
    with _lock:
        _seen.append({"ts": time.time(), "authorization": auth, "x-team": team, "x-user-id": user, "headers": all_x, "path": "/" + full_path})
    summary = f"upstream received Authorization='{auth}' x-team='{team}'"
    # OpenAI chat-completion shape so the agentgateway openai provider parses it.
    return {
        "id": "echo-0",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": "echo",
        "choices": [
            {"index": 0, "finish_reason": "stop",
             "message": {"role": "assistant", "content": summary}}
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }
