#!/usr/bin/env bash
# 03-backend-route.sh — apply the petstore OpenAPI schema, the code-mode backend,
# the Gateway, and the HTTPRoute. Idempotent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

step "Building the petstore OpenAPI ConfigMap from the published spec"
# You do not hand-write the OpenAPI document — the API publishes its own. Fetch
# it and load it into a ConfigMap under data.schema. Fall back to the pinned copy
# in yaml/ if the published URL can't be reached (airgap/offline).
SPEC_FILE="$LAB_ROOT/yaml/petstore-openapi.json"
if curl -fsS --max-time 15 "$PETSTORE_OPENAPI_URL" -o /tmp/petstore-openapi.fetched.json 2>/dev/null \
   && python3 -c 'import json; json.load(open("/tmp/petstore-openapi.fetched.json"))' 2>/dev/null; then
  SPEC_FILE=/tmp/petstore-openapi.fetched.json
  ok "fetched published spec: $PETSTORE_OPENAPI_URL"
else
  warn "could not fetch $PETSTORE_OPENAPI_URL — using pinned yaml/petstore-openapi.json"
fi
# The command a customer would run: turn the published spec into the ConfigMap.
# (--dry-run | apply so it is idempotent and re-runnable.)
kc create configmap petstore-openapi -n "$AGW_NS" \
  --from-file=schema="$SPEC_FILE" --dry-run=client -o yaml | kc apply -f - >/dev/null
ok "ConfigMap petstore-openapi created from $(basename "$SPEC_FILE") ($(wc -c <"$SPEC_FILE" | tr -d ' ') bytes)"

step "Applying the code-mode backend"
kc apply -f "$LAB_ROOT/yaml/backend.yaml" >/dev/null
ok "EnterpriseAgentgatewayBackend petstore-codemode applied (toolMode: Code)"

step "Applying the Gateway + HTTPRoute"
kc apply -f "$LAB_ROOT/yaml/gateway.yaml" >/dev/null
kc apply -f "$LAB_ROOT/yaml/httproute.yaml" >/dev/null
ok "Gateway $GATEWAY_NAME + HTTPRoute petstore-mcp applied"

step "Waiting for the gateway data plane"
wait_deploy "$AGW_NS" "$GATEWAY_NAME" 240s || warn "gateway deployment not Available yet"
SVC="$(gateway_service)"
[[ -n "$SVC" ]] && ok "gateway Service: $SVC" || warn "gateway Service not found yet"

step "Backend + route ready"
cat >&2 <<EOF
  The code-mode MCP endpoint is served at  ${MCP_PATH}  on the gateway.

  Next:
    ./scripts/port-forward.sh     # gateway → http://localhost:18770
    ./scripts/show-tools.sh       # the single run_code tool + generated TypeScript
    ./scripts/run-code.sh         # run JS that lists + groups pets, server-side
    ./scripts/ask-llm.sh "..."    # let Claude read the TS and write the JS
EOF
