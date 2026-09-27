"""Local OpenAI-compatible echo simulator. No model or external calls.

The received prompt is logged so masking is proved at the upstream, not inferred
from a response that could itself have been filtered.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ready")

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        prompt = " ".join(m.get("content", "") for m in data.get("messages", []))
        print(json.dumps({"received_prompt": prompt}), flush=True)
        body = {"id": "dd-local", "object": "chat.completion", "created": 1,
                "model": "dd-echo", "choices": [{"index": 0, "finish_reason": "stop",
                "message": {"role": "assistant", "content": prompt}}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
