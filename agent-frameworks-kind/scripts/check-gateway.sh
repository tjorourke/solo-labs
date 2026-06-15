#!/usr/bin/env bash
# check-gateway.sh — prove the Phase 1 data path with no agent involved:
#   1. an OpenAI-compatible /v1/chat/completions call returns a Claude completion
#      (the gateway translated OpenAI<->Anthropic and injected the provider key)
#   2. an MCP tools/list against /mcp returns the k8s-ops tools
# Both go through the one gateway, exactly as the crews will.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PORT="${PORT:-18080}"
step "Port-forwarding frameworks-gw -> localhost:${PORT}"
kc -n agentgateway-system port-forward svc/frameworks-gw "${PORT}:80" >/tmp/fw-gw.$$ 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null "http://localhost:${PORT}/" && break; sleep 1; done

step "1/2  LLM through the gateway (OpenAI-compatible -> Claude)"
LLM="$(curl -s -w '\n%{http_code}' "http://localhost:${PORT}/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: gateway ok\"}]}")"
CODE="$(printf '%s' "$LLM" | tail -1)"; BODY="$(printf '%s' "$LLM" | sed '$d')"
if [[ "$CODE" == "200" ]]; then
  ok "LLM 200"
  printf '%s' "$BODY" | python3 -c 'import sys,json
d=json.load(sys.stdin)
c=d.get("choices",[{}])[0].get("message",{}).get("content")
print("    model said:", (c or json.dumps(d))[:120])' 2>/dev/null || log "(could not parse body)"
else
  warn "LLM returned HTTP ${CODE}"; printf '%s\n' "$BODY" | head -3 | sed 's/^/    /' >&2
fi

step "2/2  MCP tools/list through the gateway (-> k8s-ops)"
MCP_URL="http://localhost:${PORT}/mcp" python3 - <<'PY' >&2 || warn "MCP probe failed"
import json, os, urllib.request, urllib.error

url = os.environ["MCP_URL"]
HEAD = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}

def parse(raw):
    # streamable-http returns either JSON or an SSE stream (data: {...} lines)
    raw = raw.strip()
    if raw.startswith("{"):
        return json.loads(raw)
    for line in raw.splitlines():
        if line.startswith("data:"):
            return json.loads(line[5:].strip())
    return {}

def post(payload, sid=None):
    h = dict(HEAD)
    if sid:
        h["mcp-session-id"] = sid
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.headers.get("mcp-session-id"), parse(r.read().decode("utf-8", "replace"))

try:
    sid, _ = post({"jsonrpc": "2.0", "id": "1", "method": "initialize",
                   "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                              "clientInfo": {"name": "check", "version": "0"}}})
    post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, sid)
    _, tl = post({"jsonrpc": "2.0", "id": "2", "method": "tools/list", "params": {}}, sid)
    names = [t["name"] for t in tl.get("result", {}).get("tools", [])]
    print("    tools:", ", ".join(names) if names else "(none)")
except urllib.error.HTTPError as e:
    print("    HTTP", e.code, e.read().decode("utf-8", "replace")[:200])
PY

echo "" >&2
