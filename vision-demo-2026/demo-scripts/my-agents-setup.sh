#!/usr/bin/env bash
# My agents (Demo 06) on mesh1: the MCP servers, their gateway policies and their
# AgentRegistry records, all from git.
#
#   ./demo-scripts/my-agents-setup.sh          # up: build images, apply, publish
#   ./demo-scripts/my-agents-setup.sh status   # one line per MCP server
#   ./demo-scripts/my-agents-setup.sh down     # remove the servers this script manages
#                                              (refuses while agents use them; --force overrides)
#
# Needs mesh1 with kagent and AgentRegistry (agentregistry/setup-mesh1.sh) and the kind
# registry on localhost:5001. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CONSOLE="$HERE/demo-console"
REGISTRY="${KIND_REGISTRY:-localhost:5001}"
export MESH_CONTEXT="${MESH_CONTEXT:-kind-mesh1}"

# image name | build context. Tags match the manifests in demo-console/yaml.
IMAGES=(
  "my-agents:4|$CONSOLE/agent-runtime"
  "telco-inventory:latest|$CONSOLE/telco-mcp"
  "daylight-mcp:1|$CONSOLE/daylight-mcp"
  "fun-mcp:2|$CONSOLE/fun-mcp"
)

py() { (cd "$CONSOLE" && python3 -c "$1"); }

up() {
  kubectl --context "$MESH_CONTEXT" get ns kagent >/dev/null 2>&1 \
    || { echo "kagent is not on $MESH_CONTEXT. Run ./demo-scripts/agentregistry/setup-mesh1.sh first." >&2; exit 1; }
  curl -sf "http://$REGISTRY/v2/" >/dev/null \
    || { echo "No image registry at $REGISTRY. setup.sh creates it with the kind clusters." >&2; exit 1; }
  for entry in "${IMAGES[@]}"; do
    image="${entry%%|*}"; context="${entry#*|}"
    echo "==> building $REGISTRY/$image"
    docker build -q -t "$REGISTRY/$image" "$context" >/dev/null
    docker push -q "$REGISTRY/$image" >/dev/null
  done
  echo "==> applying MCP servers, policies and AgentRegistry records"
  py 'import agents_lab as a
for line in a.setup_platform(): print("    " + line)'
  status
}

status() {
  (cd "$CONSOLE" && python3 - <<'PY'
import agents_lab as a
print(f"{'MCP server':<26}{'AgentRegistry':<20}{'Approval':<16}Gateway policy")
for r in a.platform_rows():
    print(f"{r['server']:<26}{r['registry']:<20}{r['tier']:<16}{r['policy']}")
PY
  )
}

down() {
  force=False
  [ "${2:-}" = "--force" ] && force=True
  py "import agents_lab as a
for line in a.teardown_platform(force=$force): print('    ' + line)"
}

case "${1:-up}" in
  up) up ;;
  status) status ;;
  down) down "$@" ;;
  *) echo "usage: $0 [up|status|down]" >&2; exit 2 ;;
esac
