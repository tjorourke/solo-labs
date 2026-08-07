"""Minimal OpenAI-compatible chat-completions server for the demo-7 model pool.

Answers are picked by keyword so the demo reads like a real model, and the
usage block carries real token counts so the gateway's token rate limits,
budgets and cost metrics all behave. Env: MODEL (display name), PORT.
"""
import json
import os
import signal
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# PID 1 in a container gets no default SIGTERM disposition; exit promptly so
# scaling to zero (the failover demo) takes effect in seconds, not grace-period.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

MODEL = os.environ.get("MODEL", "mock-llm")
PORT = int(os.environ.get("PORT", "8000"))

ANSWERS = [
    ("service mesh", "A service mesh is an infrastructure layer that handles service-to-service "
     "communication, moving routing, mutual TLS and telemetry out of application code and into the platform."),
    ("haiku", "Here is a haiku about the platform:\n\nQuiet packets drift,\nsidecars hum beneath the load,\n"
     "the mesh routes them home.\n\nWould you like another one, perhaps about gateways or the models behind them?"),
    ("gateway", "An AI gateway gives you one governed endpoint in front of every model provider, "
     "with identity, quotas and cost attribution enforced in one place."),
    ("kubernetes", "Kubernetes schedules and heals containerised workloads across a cluster, "
     "turning a fleet of machines into one declarative platform."),
]
DEFAULT = ("Happy to help. Routing this through the gateway means your credentials, quota "
           "and spend are all handled by the platform, so the application only needs a model name.")


def pick_answer(prompt: str) -> str:
    p = prompt.lower()
    for needle, answer in ANSWERS:
        if needle in p:
            return answer
    return DEFAULT


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("content-length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            body = {}
        messages = body.get("messages") or [{}]
        prompt = " ".join(str(m.get("content", "")) for m in messages)
        answer = pick_answer(prompt)
        max_tokens = body.get("max_tokens") or body.get("max_completion_tokens")
        words = answer.split()
        if isinstance(max_tokens, int) and 0 < max_tokens < len(words):
            words = words[:max_tokens]
            answer = " ".join(words)
        resp = {
            "id": f"chatcmpl-{uuid.uuid4()}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": MODEL,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": answer},
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": max(1, len(prompt.split())),
                "completion_tokens": len(words),
                "total_tokens": max(1, len(prompt.split())) + len(words),
            },
        }
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):  # quiet
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
