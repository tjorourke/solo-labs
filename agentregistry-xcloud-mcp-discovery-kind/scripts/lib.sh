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
MCP_IMAGE=xcloud-mcp-server:lab
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

# Password grant for a demo user against the ar-cli-password client. Prints the access token.
mint_token() {
  local user=${1:-dev-user}
  curl -s --max-time 10 \
    -d client_id=ar-cli-password -d grant_type=password \
    -d "username=$user" -d password=password -d scope=openid \
    "$KC_LOCAL/realms/agentregistry/protocol/openid-connect/token" | jq -r .access_token
}
