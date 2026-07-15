#!/usr/bin/env python3
"""Tiny MCP (streamable-HTTP) client for the demo scripts. Stdlib only.

Usage:
  mcpcall.py <url> <bearer> tools/list
  mcpcall.py <url> <bearer> tools/call <tool> '<json-args>'

Does the initialize -> notifications/initialized -> <method> handshake and prints
the JSON result (or the JSON-RPC error) so the caller can see exactly what the
gateway allowed.
"""
import json
import sys
import urllib.request

URL, BEARER, METHOD = sys.argv[1], sys.argv[2], sys.argv[3]
TOOL = sys.argv[4] if len(sys.argv) > 4 else None
ARGS = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}

HDRS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2025-06-18",
}
if BEARER:
    HDRS["Authorization"] = BEARER if BEARER.startswith("Bearer ") else f"Bearer {BEARER}"


def post(body, extra=None):
    h = dict(HDRS)
    if extra:
        h.update(extra)
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8", "replace")
    return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")


def parse(text):
    # response is either plain JSON or one or more SSE "data:" lines
    text = text.strip()
    if text.startswith("{"):
        return json.loads(text)
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            return json.loads(line[5:].strip())
    return {"raw": text[:500]}


# 1. initialize
st, hdrs, body = post({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "demo", "version": "0"}},
})
if st == 401:
    print(json.dumps({"http_status": 401, "error": "unauthorized at the gateway (JWT rejected)"}, indent=2)); sys.exit(0)
sid = hdrs.get("mcp-session-id") or hdrs.get("Mcp-Session-Id")
sess = {"Mcp-Session-Id": sid} if sid else None
if sess:
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, extra=sess)

# 2. the requested method
if METHOD == "tools/list":
    st, hdrs, body = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, extra=sess)
    d = parse(body)
    tools = [t["name"] for t in d.get("result", {}).get("tools", [])]
    print(json.dumps({"http_status": st, "tools": tools}, indent=2))
elif METHOD == "tools/call":
    st, hdrs, body = post({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": TOOL, "arguments": ARGS},
    }, extra=sess)
    d = parse(body)
    out = {"http_status": st}
    if "error" in d:
        out["error"] = d["error"]
    else:
        out["result"] = d.get("result", d)
    print(json.dumps(out, indent=2))
else:
    print(json.dumps({"error": f"unknown method {METHOD}"}))
