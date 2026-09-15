#!/usr/bin/env python3
"""tools/list against a Streamable HTTP MCP endpoint (initialize, then tools/list). Prints
the tool names, one per line. Used to show what the gateway publishes to the harness."""
import json
import sys
import urllib.request

url = sys.argv[1]
headers = {"content-type": "application/json", "accept": "application/json, text/event-stream"}

def call(body, session=None):
    h = dict(headers)
    if session:
        h["mcp-session-id"] = session
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h)
    with urllib.request.urlopen(req, timeout=30) as r:
        sid = r.headers.get("mcp-session-id")
        raw = r.read().decode()
    payload = None
    for line in raw.splitlines():
        if line.startswith("data:"):
            payload = json.loads(line[5:].strip())
    if payload is None and raw.strip():
        payload = json.loads(raw)
    return payload, sid

init, sid = call({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "lab", "version": "0"}}})
call({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid) if sid else None
tools, _ = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, sid)
for t in tools.get("result", {}).get("tools", []):
    print(t["name"])
