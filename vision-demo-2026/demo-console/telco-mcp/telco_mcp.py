#!/usr/bin/env python3
"""Minimal MCP server: fake EMEA RAN / slice inventory. Stdlib only."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json

SITES = [
    {"id": "site-dublin", "city": "Dublin", "band": "n78", "cells": 48, "slice": "embb-enterprise"},
    {"id": "site-berlin", "city": "Berlin", "band": "n78", "cells": 62, "slice": "urllc-factory"},
    {"id": "site-madrid", "city": "Madrid", "band": "n258", "cells": 31, "slice": "embb-wholesale"},
    {"id": "site-london", "city": "London", "band": "n78", "cells": 74, "slice": "embb-enterprise"},
]
SLICES = [
    {"id": "embb-enterprise", "sla_ms": 20, "isolation": "hard", "status": "ok"},
    {"id": "urllc-factory", "sla_ms": 5, "isolation": "hard", "status": "congested"},
    {"id": "embb-wholesale", "sla_ms": 40, "isolation": "shared", "status": "ok"},
]
ALARMS = [
    {"id": "alm-441", "site": "site-berlin", "slice": "urllc-factory",
     "symptom": "PRB utilisation 94 percent on n78", "severity": "major"},
    {"id": "alm-218", "site": "site-london", "slice": "embb-enterprise",
     "symptom": "S1 setup failures after last change window", "severity": "minor"},
]

TOOLS = [
    {"name": "list_sites", "description": "List RAN sites in the EMEA inventory.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "get_site", "description": "Read one site by id, for example site-berlin.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}},
    {"name": "list_slices", "description": "List 5G slices and their SLA.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "get_slice", "description": "Read one slice: SLA, isolation, congestion status.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}},
    {"name": "list_alarms", "description": "Open alarms on sites and slices.",
     "inputSchema": {"type": "object", "properties": {"site": {"type": "string"}}}},
    {"name": "congestion_now", "description": "Which slices are congested right now.",
     "inputSchema": {"type": "object", "properties": {}}},
]


def call(name, args):
    args = args or {}
    if name == "list_sites":
        return SITES
    if name == "get_site":
        return next((s for s in SITES if s["id"] == args.get("id")), {"error": "unknown site"})
    if name == "list_slices":
        return SLICES
    if name == "get_slice":
        return next((s for s in SLICES if s["id"] == args.get("id")), {"error": "unknown slice"})
    if name == "list_alarms":
        site = args.get("site")
        return [a for a in ALARMS if not site or a["site"] == site]
    if name == "congestion_now":
        return [s for s in SLICES if s["status"] != "ok"]
    return {"error": "unknown tool"}


def rpc(msg):
    method = msg.get("method")
    mid = msg.get("id")
    params = msg.get("params") or {}
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "telco-inventory", "version": "1"},
        }}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name")
        result = call(name, params.get("arguments") or {})
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": json.dumps(result)}],
        }}
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
        self.wfile.write(b"telco-inventory mcp\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 3000), H).serve_forever()
