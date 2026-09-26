#!/usr/bin/env python3
# mcp-client.py — the smallest useful MCP client, for poking a gateway endpoint
# from a cell. Streamable HTTP: initialize, then one request.
#
#   mcp-client.py <url> tools                       list the tools
#   mcp-client.py <url> call <tool> '<json args>'   call one, print its result
import json
import sys
import time
import urllib.error
import urllib.request


class Session:
    def __init__(self, url):
        self.url, self.sid = url, None
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "mcp-client", "version": "1"}})
        self.rpc("notifications/initialized", notify=True)

    def rpc(self, method, params=None, notify=False):
        body = {"jsonrpc": "2.0", "method": method}
        if not notify:
            body["id"] = 1
        if params is not None:
            body["params"] = params
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.sid:
            headers["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(self.url, json.dumps(body).encode(), headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                self.sid = r.headers.get("Mcp-Session-Id") or self.sid
                raw = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
        for line in raw.splitlines():
            if line.startswith("data:"):
                raw = line[5:]
                break
        if not raw.strip():
            return None
        data = json.loads(raw)
        if data.get("error"):
            raise SystemExit(f"  error: {data['error'].get('message')}")
        return data.get("result")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    url, verb = sys.argv[1], sys.argv[2]
    # a route that has only just been applied can take a few seconds to be served
    for attempt in range(20):
        try:
            s = Session(url)
            tools = s.rpc("tools/list", {})["tools"]
            if tools:
                break
        except (urllib.error.URLError, TypeError, KeyError, json.JSONDecodeError):
            pass
        time.sleep(2)
    else:
        raise SystemExit(f"  no tools served at {url}")

    if verb == "tools":
        print(f"  {len(tools)} tools at {url}")
        for t in tools:
            desc = " ".join((t.get("description") or "").split())
            print(f"  - {t['name']:<26} {desc[:70]}")
        return
    if verb == "call":
        name = sys.argv[3]
        args = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
        res = s.rpc("tools/call", {"name": name, "arguments": args})
        out = res.get("structuredContent")
        if out is None:
            text = "".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
            try:
                out = json.loads(text)
            except json.JSONDecodeError:
                out = text
        print(f"  {name}({json.dumps(args)})")
        print(json.dumps(out, indent=2) if not isinstance(out, str) else out)
        if res.get("isError"):
            raise SystemExit(1)
        return
    raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
