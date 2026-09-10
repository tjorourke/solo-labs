#!/usr/bin/env bash
# try-merge.sh <agent-deployment> [pullNumber] — ask the gateway to merge, as that agent.
#
# This is the enforcement proof, and it deliberately does NOT go through the model. An
# agent saying "I cannot merge" is the model being agreeable. This is the request the
# model would have made, sent straight at the gateway from inside the agent's own pod,
# so it carries the agent's real SPIFFE identity and nothing else.
#
# The pull request number defaults to one that does not exist. If policy ever failed to
# propagate, GitHub answers 404 and nothing is merged, and the error text tells you
# which of the two happened:
#
#   refused by the gateway  ->  "Unknown tool: merge_pull_request"  (never reached GitHub)
#   allowed by the gateway  ->  "404 Not Found" from api.github.com  (reached GitHub)
set -euo pipefail
DEP="${1:?usage: try-merge.sh <agent-deployment> [pullNumber]}"
PR="${2:-99999}"
K="kubectl --context ${CTX:-kind-mesh1}"
NS="${NS:-kagent}"
URL="http://github-mcp.${NS}.svc.cluster.local/"
OWNER="${DEMO_REPO%/*}"; OWNER="${OWNER:-tjorourke}"
NAME="${DEMO_REPO#*/}"; NAME="${NAME:-kagent}"

echo "  asking the gateway to merge ${OWNER}/${NAME}#${PR}, as ${DEP}"
$K -n "$NS" exec "deploy/$DEP" -- sh -c '
  INIT='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"try-merge","version":"1"}}}'"'"'
  SID=$(wget -qS -O /dev/null --header="Content-Type: application/json" \
    --header="Accept: application/json, text/event-stream" --post-data="$INIT" '"$URL"' 2>&1 \
    | grep -i "mcp-session-id" | awk "{print \$2}")
  BODY='"'"'{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"merge_pull_request","arguments":{"owner":"'"$OWNER"'","repo":"'"$NAME"'","pullNumber":'"$PR"'}}}'"'"'
  # --content-on-error: the gateway refuses with a non-2xx AND a JSON-RPC error body,
  # and without this wget throws the body away and all you see is "400 Bad Request",
  # which does not tell you whether policy or GitHub said no.
  OUT=$(wget -q --content-on-error -O- \
    --header="Content-Type: application/json" --header="Accept: application/json, text/event-stream" \
    ${SID:+--header="Mcp-Session-Id: $SID"} --post-data="$BODY" '"$URL"' 2>&1 | sed "s/^data: //")
  echo "$OUT" | grep -vE "^(Connecting|--|HTTP request|Length|Saving|Resolving|event:)" | grep . | head -3' 2>&1 | sed 's/^/    /'
