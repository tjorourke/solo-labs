#!/usr/bin/env python3
"""Solve x² − 5x + 6 = 0 with a calculator MCP server, through mesh1 agentgateway.

The same model and the same question in two tool modes. In Standard the gateway
serves add/sub/mul/div/sqrt/pow and the model calls them one at a time. In Code
it serves a single run_code tool and the model writes one program that calls
them. Tokens are the model's own usage numbers, billed like the GitHub run.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

import live_run
from live_run import Mcp, anthropic, emit_metrics, kubectl, usd

ROOT = Path(__file__).resolve().parent
LAB = ROOT.parent
NS = "agentgateway-system"
MODE_MAP = {"standard": "Standard", "code": "Code"}
PROMPT = "Solve x² − 5x + 6 = 0. Give both roots."
SYSTEM = {
    "standard": (
        "You solve maths problems with the calculator tools. Use a tool for every arithmetic "
        "operation, including each multiplication, subtraction, square root and division. "
        "Never work anything out yourself. Use the quadratic formula. When you have both "
        "roots, reply with one line: x = {r1, r2}."
    ),
    "code": (
        "You solve maths problems with the calculator. The calculator's add, sub, mul, div, "
        "sqrt and pow are already defined inside run_code as async functions (see its "
        "Available API). Each takes one object and resolves to an object: "
        "await mul({a: 2, b: 3}) gives {result: 6}, and sqrt takes {x}. "
        "Write one program for run_code that awaits them for every "
        "arithmetic operation, using the quadratic formula. Do not define your own "
        "functions, use Math, or apply + - * / to numbers yourself. End the program with "
        "an expression that evaluates to both roots. When you have them, reply with one "
        "line: x = {r1, r2}."
    ),
}
BACKEND = """apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata: { name: calc-mcp, namespace: agentgateway-system }
spec:
  entMcp:
    toolMode: %s
    sessionRouting: Stateful
    targets:
    - name: calc
      static: { host: calc-mcp.agentgateway-system.svc.cluster.local, port: 3000, protocol: StreamableHTTP, path: /mcp }
"""
ROUTE = """apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: calc-mcp, namespace: agentgateway-system }
spec:
  parentRefs: [{ name: ar-ingress }]
  hostnames: ["calc.%s.sslip.io"]
  rules:
  - backendRefs: [{ group: enterpriseagentgateway.solo.io, kind: EnterpriseAgentgatewayBackend, name: calc-mcp }]
"""


def apply(doc: str):
    import subprocess
    subprocess.run(["kubectl", "--context", live_run.CTX, "apply", "-f", "-"],
                   input=doc.encode(), check=True, capture_output=True)


def ensure(mode: str) -> str:
    """The calculator, its backend in the requested mode and a route. Returns the MCP URL."""
    lb = kubectl("-n", NS, "get", "gateway", "ar-ingress", "-o",
                 "jsonpath={.status.addresses[0].value}", check=False).stdout.strip()
    if not lb:
        raise RuntimeError("ar-ingress has no address on mesh1")
    if kubectl("-n", NS, "get", "deploy", "calc-mcp", check=False).returncode != 0:
        kubectl("apply", "-f", str(LAB / "demo-scripts" / "yaml-codemode" / "calc-mcp.yaml"))
    kubectl("-n", NS, "rollout", "status", "deploy/calc-mcp", "--timeout=120s")
    apply(BACKEND % MODE_MAP[mode])
    apply(ROUTE % lb)
    return f"http://calc.{lb}.sslip.io/"


def wait_mode(url: str, mode: str, tries: int = 30):
    for _ in range(tries):
        try:
            mcp = Mcp(url)
            tools = mcp.tools()
            names = {t["name"] for t in tools}
            if (mode == "code") == ("run_code" in names) and names:
                return mcp, tools
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError(f"gateway never served toolMode {MODE_MAP[mode]}")


def anthropic_key() -> str:
    import subprocess
    out = subprocess.check_output(
        ["bash", "-c", f'set -a; . "{live_run.SECRETS}" >/dev/null 2>&1; set +a; printf %s "$ANTHROPIC_API_KEY"'], text=True)
    if not out:
        raise RuntimeError("ANTHROPIC_API_KEY is not set in the secrets file")
    return out


def list_mode_tools(mode: str) -> list[str]:
    mcp, tools = wait_mode(ensure(mode), mode)
    return sorted(t["name"] for t in tools)


def run(mode: str, emit):
    t0 = time.time()
    emit({"type": "status", "text": "attaching the calculator MCP server on mesh1"})
    url = ensure(mode)
    emit({"type": "status", "text": f"{url}  toolMode {MODE_MAP[mode]}"})
    mcp, tools = wait_mode(url, mode)
    emit({"type": "tools", "count": len(tools), "names": [t["name"] for t in tools]})
    key = anthropic_key()
    messages = [{"role": "user", "content": PROMPT}]
    spec = live_run.to_anthropic_tools(tools)
    loops = tin = tout = 0
    answer = ""
    for _ in range(30):
        msg = anthropic(key, messages, spec, system=SYSTEM[mode])
        usage = msg.get("usage") or {}
        tin += int(usage.get("input_tokens") or 0)
        tout += int(usage.get("output_tokens") or 0)
        content = msg.get("content") or []
        uses = [b for b in content if b.get("type") == "tool_use"]
        emit_metrics(emit, t0, loops, tin, tout, "model")
        if not uses:
            answer = "\n".join(b.get("text", "") for b in content if b.get("type") == "text").strip()
            break
        results = []
        for u in uses:
            loops += 1
            args = u.get("input") or {}
            detail = args.get("code", "") if u["name"] == "run_code" else json.dumps(args)
            try:
                text = live_run.parse_tool_text(mcp.invoke(u["name"], args))
            except Exception as e:
                text = f"tool error: {e}"
            emit({"type": "step", "title": u["name"], "detail": detail[:2400], "result": text[:200]})
            results.append({"type": "tool_result", "tool_use_id": u["id"], "content": text[:8000]})
        messages += [{"role": "assistant", "content": content}, {"role": "user", "content": results}]
        emit_metrics(emit, t0, loops, tin, tout, "model")
    emit({"type": "answer", "text": answer, "model": live_run.MODEL})
    emit({"type": "done", "live": True, "loops": loops, "tokens_in": tin, "tokens_out": tout,
          "tokens": tin + tout, "ms": int((time.time() - t0) * 1000), "usd": round(usd(tin, tout), 4),
          "tools": len(tools), "model": live_run.MODEL})


if __name__ == "__main__":
    import sys
    run(sys.argv[1] if len(sys.argv) > 1 else "standard", lambda ev: print(json.dumps(ev), flush=True))
