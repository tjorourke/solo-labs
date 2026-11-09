# Shared settings for the xcloud-mcp lab scripts. Sourced, not run.
CLUSTER=xcloud-mcp
CTX=kind-xcloud-mcp
AGW_VERSION=v2026.10.2
AR_VERSION=2026.10.0
GATEWAY_API_URL=https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
AGW_CHARTS=oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts
AR_CHART=oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise
KC_HOST=keycloak.127.0.0.1.nip.io
KEYCLOAK_ISSUER=http://${KC_HOST}:8180/realms/agentregistry
KC_LOCAL=http://127.0.0.1:8180
GW_LOCAL=http://localhost:8080
AR_MCP_LOCAL=http://localhost:31313/mcp
# The two MCP servers run as plain processes on the laptop, outside the cluster. Pods reach them through
# host.docker.internal (checked 9 Nov 2026 on OrbStack 29.8.2: a pod in kind got 200 from a server bound to 127.0.0.1).
FASTMCP_VERSION=4.1.6
MCP_BIND_HOST=${MCP_BIND_HOST:-127.0.0.1}
# service:port:route. cloud-a holds health and finance, cloud-b holds telco and compute.
MCP_SERVICES="health-records:8001:health finance-payments:8002:finance telco-network:8003:telco compute-inventory:8004:compute"
MCP_NAMES="health-records finance-payments telco-network compute-inventory"
STATE_DIR=.state

mcp_headers=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

# mcp_init URL TOKEN -> prints the mcp-session-id (empty if none)
mcp_init() {
  local url=$1 token=${2:-} auth=()
  [[ -n $token ]] && auth=(-H "Authorization: Bearer $token")
  curl -s --max-time 10 -D - -o /dev/null "${mcp_headers[@]}" "${auth[@]}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"lab-curl","version":"0.1"}}}' \
    "$url" | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r' >"${TMPDIR:-/tmp}/lab-mcp-sid"
  local sid; sid=$(cat "${TMPDIR:-/tmp}/lab-mcp-sid")
  [[ -n $sid ]] && curl -s --max-time 5 -o /dev/null "${mcp_headers[@]}" "${auth[@]}" -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$url"
  echo "$sid"
}

# mcp_rpc URL TOKEN SESSION JSON -> prints body; HTTP status on the last line
mcp_rpc() {
  local url=$1 token=$2 session=$3 body=$4
  curl -s --max-time 15 -w '\n%{http_code}\n' "${mcp_headers[@]}" \
    -H "Authorization: Bearer $token" -H "mcp-session-id: $session" -d "$body" "$url"
}

# Starts the three laptop port-forwards in the background and records their PIDs.
start_port_forwards() {
  mkdir -p "$STATE_DIR"
  kubectl --context "$CTX" -n keycloak port-forward svc/keycloak 8180:8180 --address=127.0.0.1 >"$STATE_DIR/pf-keycloak.log" 2>&1 &
  echo $! >"$STATE_DIR/pf-keycloak.pid"
  kubectl --context "$CTX" -n agentgateway-system port-forward deployment/agentgateway-proxy 8080:80 --address=127.0.0.1 >"$STATE_DIR/pf-gateway.log" 2>&1 &
  echo $! >"$STATE_DIR/pf-gateway.pid"
  kubectl --context "$CTX" -n agentregistry-system port-forward svc/agentregistry-enterprise-server 12121:12121 31313:31313 --address=127.0.0.1 >"$STATE_DIR/pf-registry.log" 2>&1 &
  echo $! >"$STATE_DIR/pf-registry.pid"
  sleep 3
}

stop_port_forwards() {
  local f
  for f in "$STATE_DIR"/pf-*.pid; do
    [[ -e $f ]] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  done
}

# kagent step: Solo UI on 19480 and the kagent controller API on 18083. Same PID files, so stop_port_forwards stops them.
start_kagent_port_forwards() {
  mkdir -p "$STATE_DIR"
  kubectl --context "$CTX" -n agentgateway-system port-forward svc/solo-enterprise-ui 19480:80 --address=127.0.0.1 >"$STATE_DIR/pf-solo-ui.log" 2>&1 &
  echo $! >"$STATE_DIR/pf-solo-ui.pid"
  kubectl --context "$CTX" -n kagent port-forward svc/kagent-controller 18083:8083 --address=127.0.0.1 >"$STATE_DIR/pf-kagent.log" 2>&1 &
  echo $! >"$STATE_DIR/pf-kagent.pid"
  sleep 3
}

stop_kagent_port_forwards() {
  local f
  for f in "$STATE_DIR"/pf-solo-ui.pid "$STATE_DIR"/pf-kagent.pid; do
    [[ -e $f ]] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  done
}

# ask_agent USER TEXT -> prints the A2A JSON reply from cloud-ops. Uses the lab password grant (mint_token).
ask_agent() {
  local tok; tok=$(mint_token "$1")
  curl -s --max-time 180 -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    http://localhost:18083/api/a2a/kagent/cloud-ops/ \
    -d "$(jq -nc --arg t "$2" '{jsonrpc:"2.0",id:"1",method:"message/send",params:{message:{role:"user",messageId:("m"+(now|tostring)),kind:"message",parts:[{kind:"text",text:$t}]}}}')"
}

mcp_port() { local e; for e in $MCP_SERVICES; do [[ ${e%%:*} == "$1" ]] && { e=${e#*:}; echo "${e%%:*}"; return; }; done; }

# Starts the four MCP servers on 8001 to 8004 with uv. PIDs and logs go in .state/.
servers_up() {
  command -v uv >/dev/null || { echo 'Missing uv (brew install uv)' >&2; return 1; }
  mkdir -p "$STATE_DIR"
  local c port pid
  for c in $MCP_NAMES; do
    port=$(mcp_port "$c")
    if [[ -f $STATE_DIR/mcp-$c.pid ]] && kill -0 "$(cat "$STATE_DIR/mcp-$c.pid")" 2>/dev/null; then
      echo "$c already running (PID $(cat "$STATE_DIR/mcp-$c.pid"))"; continue
    fi
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then echo "Port $port is already in use" >&2; return 1; fi
    SERVICE=$c PORT=$port BIND_HOST=$MCP_BIND_HOST nohup uv run --quiet --python 3.12 --with "fastmcp==$FASTMCP_VERSION" \
      mcp-servers/server.py >"$STATE_DIR/mcp-$c.log" 2>&1 &
    echo $! >"$STATE_DIR/mcp-$c.pid"
  done
  for c in $MCP_NAMES; do
    port=$(mcp_port "$c")
    for _ in $(seq 1 60); do lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 1; done
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || { echo "$c did not start; see $STATE_DIR/mcp-$c.log" >&2; return 1; }
    echo "$c listening on $MCP_BIND_HOST:$port (PID $(cat "$STATE_DIR/mcp-$c.pid"))"
  done
}

# Stops all four servers, then reads back that the PIDs are gone and the ports are free.
servers_down() {
  local c port pid left=0
  for c in $MCP_NAMES; do
    [[ -f $STATE_DIR/mcp-$c.pid ]] || continue
    pid=$(cat "$STATE_DIR/mcp-$c.pid")
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  sleep 2
  for c in $MCP_NAMES; do
    port=$(mcp_port "$c")
    if [[ -f $STATE_DIR/mcp-$c.pid ]]; then
      pid=$(cat "$STATE_DIR/mcp-$c.pid")
      if kill -0 "$pid" 2>/dev/null; then echo "$c PID $pid still running" >&2; left=1; else rm -f "$STATE_DIR/mcp-$c.pid"; fi
    fi
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then echo "Port $port still in use" >&2; left=1; fi
  done
  [[ $left == 0 ]] && echo 'All four MCP servers stopped; ports 8001 to 8004 are free.'
  return $left
}

servers_status() {
  local c port
  for c in $MCP_NAMES; do
    port=$(mcp_port "$c")
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "$c: listening on $port (PID file: $(cat "$STATE_DIR/mcp-$c.pid" 2>/dev/null || echo none))"
    else echo "$c: not running"; fi
  done
}

# Password grant for a demo user against the ar-cli-password client. Prints the access token.
mint_token() {
  local user=${1:-dev-user}
  curl -s --max-time 10 \
    -d client_id=ar-cli-password -d grant_type=password \
    -d "username=$user" -d password=password -d scope=openid \
    "$KC_LOCAL/realms/agentregistry/protocol/openid-connect/token" | jq -r .access_token
}
