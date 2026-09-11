#!/usr/bin/env bash
# token.sh — mint a caller token from the cluster's Keycloak, and print it.
#
# The published MCP listener requires one (yaml/12-ingress-jwt.yaml). A workload gets its
# identity from the mesh, as a certificate the waypoint reads; a human at a laptop has no such
# thing, so the published route asks for a token instead.
#
# This proves who the CALLER is. It is not the GitHub credential: that stays in a Secret the
# gateway reads, and is never sent by, or visible to, whoever holds this token.
#
#   token                      print one
#   curl -H "Authorization: Bearer $(token)" ...
#
# Cached for a minute so a demo does not mint one per call.
set -euo pipefail
CACHE=/tmp/mcp-token
LB="${LB:-$(kubectl --context "${CTX:-kind-mesh1}" -n agentgateway-system get gateway ar-ingress \
     -o jsonpath='{.status.addresses[0].value}')}"
if [ ! -s "$CACHE" ] || [ -n "$(find "$CACHE" -mmin +1 2>/dev/null)" ]; then
  curl -s -m 20 \
    "http://keycloak.${LB}.sslip.io/realms/${KEYCLOAK_REALM:-agentregistry}/protocol/openid-connect/token" \
    -d grant_type=password \
    -d "client_id=${KAGENT_CLI_CLIENT:-kagent-cli-password}" \
    -d "username=${AS_USER:-admin-user}" \
    -d "password=${AS_PASSWORD:-password}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' > "$CACHE"
fi
[ -s "$CACHE" ] || { echo "could not mint a token from keycloak.${LB}.sslip.io" >&2; exit 1; }
cat "$CACHE"
