#!/usr/bin/env python3
# mcp-solve.py — solve x² − 5x + 6 = 0 through the calculator MCP server fronted by
# agentgateway, and report how many client-visible tool calls it took. Auto-detects
# the gateway's toolMode: if the gateway exposes run_code (toolMode: Code) it solves
# in ONE call; otherwise (Standard) it makes one call per operation (11).
#
#   python3 mcp-solve.py --url http://localhost:8099/ --host calc.<LB>.sslip.io
import argparse, json, sys, urllib.request

G,Y,B,C,X = '\033[32m','\033[33m','\033[1m','\033[36m','\033[0m'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8099/")
    ap.add_argument("--host", required=True)
    a = ap.parse_args()
    calls = 0
    def rpc(method, params=None, sid=None, notify=False):
        body = {"jsonrpc": "2.0", "method": method}
        if not notify: body["id"] = 1
        if params is not None: body["params"] = params
        h = {"Host": a.host, "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream"}
        if sid: h["Mcp-Session-Id"] = sid
        r = urllib.request.urlopen(urllib.request.Request(a.url, data=json.dumps(body).encode(), headers=h), timeout=30)
        data = None
        for line in r.read().decode(errors="replace").splitlines():
            if line.startswith("data:"):
                try: data = json.loads(line[5:].strip())
                except Exception: pass
        return r.headers.get("Mcp-Session-Id"), data

    sid, _ = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "mcp-solve", "version": "1"}})
    rpc("notifications/initialized", sid=sid, notify=True)
    _, d = rpc("tools/list", {}, sid=sid)
    tools = [t["name"] for t in d["result"]["tools"]]
    code_mode = "run_code" in tools
    mode = "Code" if code_mode else "Standard"
    print(f"  {C}{B}tools exposed by the gateway ({mode} mode):{X} {tools}")

    def num(v):
        if isinstance(v, (int, float)): return float(v)
        if isinstance(v, dict): return float(v.get("result", v.get("success", 0)))
        return float(v)
    def call(name, **args):
        nonlocal calls; calls += 1
        _, d = rpc("tools/call", {"name": name, "arguments": args}, sid=sid)
        res = d["result"]
        sc = res.get("structuredContent")
        if sc: return num(sc.get("result", sc))
        return float(res["content"][0]["text"])

    if code_mode:
        js = ("const a=1,b=-5,c=6;"
              "const n=v=>typeof v==='number'?v:(v&&v.result!==undefined?v.result:Number(v));"
              "const t1=n(await mul({a:b,b:b})),t2=n(await mul({a:4,b:a})),t3=n(await mul({a:t2,b:c})),"
              "d=n(await sub({a:t1,b:t3})),r=n(await sqrt({x:d})),nb=n(await mul({a:-1,b:b})),"
              "n1=n(await add({a:nb,b:r})),n2=n(await sub({a:nb,b:r})),dn=n(await mul({a:2,b:a})),"
              "x1=n(await div({a:n1,b:dn})),x2=n(await div({a:n2,b:dn}));"
              "const result=[x2,x1];result")
        calls += 1
        _, d = rpc("tools/call", {"name": "run_code", "arguments": {"code": js}}, sid=sid)
        sc = d["result"].get("structuredContent", {})
        roots = sc.get("success") or sc.get("result") or []
        colour = G
    else:
        a1, b1, c1 = 1.0, -5.0, 6.0
        t1 = call("mul", a=b1, b=b1); t2 = call("mul", a=4, b=a1); t3 = call("mul", a=t2, b=c1)
        dd = call("sub", a=t1, b=t3); r = call("sqrt", x=dd); nb = call("mul", a=-1, b=b1)
        n1 = call("add", a=nb, b=r); n2 = call("sub", a=nb, b=r); dn = call("mul", a=2, b=a1)
        x1 = call("div", a=n1, b=dn); x2 = call("div", a=n2, b=dn)
        roots = sorted([x1, x2]); colour = Y
    roots = sorted(int(x) if float(x).is_integer() else x for x in roots)
    unit = "run_code call" if code_mode else "tool calls"
    print(f"  {colour}{B}{mode} mode: {calls} {unit}{X}  →  x = {{{', '.join(str(x) for x in roots)}}}")

if __name__ == "__main__":
    main()
