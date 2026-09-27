#!/usr/bin/env python3
# mcp-agent.py — the smallest agent: Claude plus the tools one MCP endpoint serves.
#
# 1. list the endpoint's tools (MCP tools/list, through agentgateway)
# 2. send Claude the task and those tool definitions (Anthropic Messages API)
# 3. when Claude asks for a tool, call it through agentgateway (MCP tools/call)
#    and hand the result back; repeat until Claude answers in words
#
#   ANTHROPIC_API_KEY=... mcp-agent.py --url http://pet-workflow.<LB>.sslip.io/ "<task>"
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module

Session = import_module("mcp-client").Session


def claude(key, model, messages, tools):
    body = {"model": model, "max_tokens": 1024, "messages": messages, "tools": tools}
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", json.dumps(body).encode(), {
        "Content-Type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise SystemExit(f"  Anthropic HTTP {e.code}: {e.read()[:300].decode('utf-8', 'replace')}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", default=os.environ.get("DEMO_MODEL", "claude-haiku-4-5"))
    ap.add_argument("task")
    a = ap.parse_args()
    key = os.environ.get("ANTHROPIC_API_KEY") or sys.exit("  ANTHROPIC_API_KEY is not set")

    s = Session(a.url)
    tools = s.rpc("tools/list", {})["tools"]
    print(f"  Claude ({a.model}) is given the tools this endpoint serves: {', '.join(t['name'] for t in tools)}")
    print(f"  Task for Claude: {a.task}\n")
    spec = [{"name": t["name"], "description": t.get("description") or t["name"],
             "input_schema": t.get("inputSchema") or {"type": "object"}} for t in tools]

    messages = [{"role": "user", "content": a.task}]
    calls = tokens = 0
    for _ in range(8):
        msg = claude(key, a.model, messages, spec)
        tokens += msg["usage"]["input_tokens"] + msg["usage"]["output_tokens"]
        uses = [b for b in msg["content"] if b["type"] == "tool_use"]
        if not uses:
            print("\n  Claude's answer:")
            print("\n".join("  " + line for b in msg["content"] if b["type"] == "text" for line in b["text"].splitlines()))
            break
        results = []
        for u in uses:
            calls += 1
            res = s.rpc("tools/call", {"name": u["name"], "arguments": u["input"]})
            text = "".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
            print(f"  {calls}. Claude asks for {u['name']}({json.dumps(u['input'])})")
            print(f"     agentgateway runs it and returns: {text[:160]}")
            results.append({"type": "tool_result", "tool_use_id": u["id"], "content": text})
        messages += [{"role": "assistant", "content": msg["content"]}, {"role": "user", "content": results}]
    print(f"\n  {calls} tool calls, {tokens} Claude tokens ({a.model})")


if __name__ == "__main__":
    main()
