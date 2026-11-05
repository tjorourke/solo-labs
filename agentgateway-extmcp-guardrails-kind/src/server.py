#!/usr/bin/env python3
# crm-mcp: a minimal MCP server, Python stdlib only.
#
# Two tools on purpose: one read-only, one destructive. The lab's guardrail
# server gates the destructive one and annotates it at discovery time; this
# backend has no idea the guardrail exists.

import json
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POD = socket.gethostname()

CONTACTS = [
    {"id": "c-1", "name": "Priya Shah", "email": "priya.shah@example.com"},
    {"id": "c-2", "name": "Tom Reyes", "email": "tom.reyes@example.com"},
    {"id": "c-3", "name": "Aisha Bello", "email": "aisha.bello@example.com"},
]

TOOLS = [
    {
        "name": "search_contacts",
        "description": "Search the CRM contact list by name.",
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
        },
    },
    {
        "name": "delete_contact",
        "description": "Permanently delete a contact from the CRM.",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"],
        },
    },
]


def rpc_error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def rpc_result(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def text_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def handle_tools_call(rid, params):
    name = params.get("name", "")
    args = params.get("arguments") or {}

    if name == "search_contacts":
        q = (args.get("query") or "").lower()
        hits = [c for c in CONTACTS if q in c["name"].lower()] if q else CONTACTS
        lines = "\n".join("%s  %s  <%s>" % (c["id"], c["name"], c["email"]) for c in hits)
        return rpc_result(rid, text_result("%d contact(s) (served by pod %s):\n%s" % (len(hits), POD, lines)))

    if name == "delete_contact":
        cid = args.get("id", "")
        match = next((c for c in CONTACTS if c["id"] == cid), None)
        if match is None:
            return rpc_result(rid, text_result("no such contact: %s" % cid, True))
        log("delete_contact: deleted %s (%s) -- backend never checked who asked" % (cid, match["name"]))
        return rpc_result(rid, text_result("deleted %s (%s) (pod %s)" % (cid, match["name"], POD)))

    return rpc_error(rid, -32602, "unknown tool: %s" % name)


def handle(body):
    rid = body.get("id")
    method = body.get("method", "")
    params = body.get("params") or {}

    if method.startswith("notifications/"):
        return None

    if method == "initialize":
        return rpc_result(
            rid,
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "crm-mcp", "version": "1.0.0"},
            },
        )

    if method == "tools/list":
        return rpc_result(rid, {"tools": TOOLS})

    if method == "tools/call":
        return handle_tools_call(rid, params)

    return rpc_error(rid, -32601, method)


def log(msg):
    print("[%s] %s" % (POD, msg), flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, payload=None):
        data = json.dumps(payload).encode() if payload is not None else b""
        self.send_response(code)
        if payload is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"ok": True, "pod": POD})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/mcp":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except Exception:
            self._send(400, {"error": "invalid JSON"})
            return
        log("%s" % body.get("method"))
        response = handle(body)
        if response is None:
            self._send(202)
        else:
            self._send(200, response)


if __name__ == "__main__":
    log("crm-mcp serving MCP on :8000")
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
