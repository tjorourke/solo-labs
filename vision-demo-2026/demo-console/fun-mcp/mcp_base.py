"""Tiny streamable-HTTP MCP server, stdlib only. Shared by the fun servers in this image."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json


def serve(name, tools, calls, port=3000):
    def call(tool, args):
        fn = calls.get(tool)
        if not fn:
            return {"error": "unknown tool"}
        try:
            return fn(args or {})
        except (ValueError, KeyError, TypeError) as e:
            return {"error": str(e)}

    def rpc(msg):
        method = msg.get("method")
        mid = msg.get("id")
        params = msg.get("params") or {}
        if method == "initialize":
            return {"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": name, "version": "1"},
            }}
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": mid, "result": {"tools": tools}}
        if method == "tools/call":
            result = call(params.get("name"), params.get("arguments") or {})
            return {"jsonrpc": "2.0", "id": mid, "result": {
                "content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}],
                "isError": isinstance(result, dict) and "error" in result,
            }}
        if method == "ping":
            return {"jsonrpc": "2.0", "id": mid, "result": {}}
        if method and method.startswith("notifications/"):
            return None
        if mid is not None:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method}}
        return None

    class H(BaseHTTPRequestHandler):
        def log_message(self, *args):
            return

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            try:
                msg = json.loads(self.rfile.read(n) or b"{}")
            except json.JSONDecodeError:
                self.send_error(400)
                return
            out = rpc(msg)
            if out is None:
                self.send_response(202)
                self.end_headers()
                return
            body = json.dumps(out).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"{name} mcp\n".encode())

    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
