#!/usr/bin/env bash
# 06-mcp.sh — the sre-lab namespace, kagent-tools behind the gateway with a four-tool
# allow-list, and the OpenClaw harness pointed at that endpoint.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
mkdir -p "$CAPTURES"

step "sre-lab: seven workloads, four broken on purpose"
kc apply -f "$YAML/50-sre-lab.yaml" >/dev/null
sleep 20
kc -n "$SRE_NS" get pods

step "kagent-tools behind ${GATEWAY_NAME}/mcp with the read-only allow-list"
kc apply -f "$YAML/51-tools-backend.yaml" -f "$YAML/52-tools-policy.yaml"
sleep 5
gateway_pf
all_tools=$(python3 "$SCRIPT_DIR/mcp-list.py" "http://kagent-tools.${NS}.svc.cluster.local:8084/mcp" 2>/dev/null || true)
gw_tools=""
for _ in $(seq 1 20); do
  gw_tools=$(python3 "$SCRIPT_DIR/mcp-list.py" "http://127.0.0.1:${GATEWAY_PORT}/mcp" 2>/dev/null || true)
  [[ $(printf '%s\n' "$gw_tools" | grep -c .) -eq 4 ]] && break
  sleep 3
done
printf '%s\n' "$gw_tools" | tee "$CAPTURES/mcp-tools-through-gateway.txt"
[[ $(printf '%s\n' "$gw_tools" | grep -c .) -eq 4 ]] || die "expected 4 tools through the gateway, got: $gw_tools"
# The unfiltered count, straight from kagent-tools (a path the harness does not have).
__start_pf svc/kagent-tools 18084 8084 "http://127.0.0.1:18084/metrics" "$NS" || true
python3 "$SCRIPT_DIR/mcp-list.py" "http://127.0.0.1:18084/mcp" 2>/dev/null | grep -c . > "$CAPTURES/mcp-tools-direct-count.txt" || true
pkill -f "port-forward .*kagent-tools 18084:8084" 2>/dev/null || true
ok "gateway publishes 4 tools (kagent-tools serves $(cat "$CAPTURES/mcp-tools-direct-count.txt" 2>/dev/null || echo '?') directly)"

step "register the gateway endpoint in OpenClaw's MCP client registry"
# kagent 0.10.1 has no AgentHarness field for MCP servers and does not pass spec.env to the
# openclaw backend, so the registry entry is written with OpenClaw's own CLI, inside the
# actor, through the ACP path. It is harness state: it lives with the shared actor.
mcp_json="{\"url\":\"http://${GATEWAY_HOST}/mcp\",\"transport\":\"streamable-http\"}"
"$SCRIPT_DIR/ask.sh" --approve --capture mcp-register \
  "Run exactly this command with the exec tool and nothing else: openclaw mcp set kubernetes '${mcp_json}' . Then run: openclaw mcp list . Report both outputs verbatim." \
  | tee "$CAPTURES/mcp-register.txt"
grep -q "kubernetes" "$CAPTURES/mcp-register.txt" || die "OpenClaw did not report the kubernetes MCP server"
ok "OpenClaw registered ${GATEWAY_HOST}/mcp as MCP server 'kubernetes'"
