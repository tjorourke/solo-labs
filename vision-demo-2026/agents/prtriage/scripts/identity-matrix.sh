#!/usr/bin/env bash
# identity-matrix.sh — one GitHub integration, three callers, three answers.
#
# Runs the same tools/list against the same waypoint from each caller and prints what
# each is allowed to see. The point is that nothing about the request differs except
# who is making it: same URL, same body, no credentials anywhere.
#
#   triage agent   reads pull requests, cannot see the merge tool
#   release agent  reads the same pull requests, can see the merge tool
#   no identity    refused outright, because it matches neither clause
set -euo pipefail
K="kubectl --context ${CTX:-kind-mesh1}"
NS="${NS:-kagent}"
URL="http://github-mcp.${NS}.svc.cluster.local/"

tools_seen() { # tools_seen <deployment>
  $K -n "$NS" exec "deploy/$1" -- sh -c '
    INIT='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"matrix","version":"1"}}}'"'"'
    SID=$(wget -qS -O /dev/null --header="Content-Type: application/json" \
      --header="Accept: application/json, text/event-stream" --post-data="$INIT" '"$URL"' 2>&1 \
      | grep -i "mcp-session-id" | awk "{print \$2}")
    wget -qO- --header="Content-Type: application/json" --header="Accept: application/json, text/event-stream" \
      ${SID:+--header="Mcp-Session-Id: $SID"} \
      --post-data='"'"'{"jsonrpc":"2.0","id":2,"method":"tools/list"}'"'"' '"$URL"' 2>&1 \
      | sed "s/^data: //" | grep -o "\"name\":\"[a-z_]*\"" | sed "s/\"name\"://;s/\"//g" | sort | tr "\n" " "' 2>/dev/null || true
}

row() { # row <label> <tools...>
  local label="$1"; shift
  local tools="$*"
  local read="no" merge="hidden"
  [[ "$tools" == *list_pull_requests* ]] && read="yes"
  [[ "$tools" == *merge_pull_request* ]] && merge="VISIBLE"
  [[ -z "${tools// }" ]] && { read="DENIED"; merge="DENIED"; }
  printf "  %-22s %-12s %-10s %s\n" "$label" "$read" "$merge" "${tools:-(nothing)}"
}

echo
printf "  %-22s %-12s %-10s %s\n" "identity" "read PRs" "merge tool" "tools returned"
printf "  %-22s %-12s %-10s %s\n" "----------------------" "------------" "----------" "--------------"
row "triage agent"  "$(tools_seen prtriagejava)"
row "release agent" "$(tools_seen releasejava)"

# A caller with no mesh identity. my-mcp is an ordinary pod in the namespace: it is in
# the mesh, so it HAS an identity, just not one the policy names. That is the honest
# third row, and it is the common case: some other workload that found the endpoint.
if $K -n "$NS" get deploy/my-mcp >/dev/null 2>&1; then
  row "another workload" "$(tools_seen my-mcp)"
else
  echo "  (deploy/my-mcp not present, so the unnamed-identity row is skipped)"
fi
echo
