#!/usr/bin/env bash
# wait-for-mode.sh <Standard|Search|Code|CodeSearch> — wait until the gateway is
# actually serving that tool surface, on both paths.
#
# WHY NOT A SLEEP
# A `sleep 8` after patching toolMode is a guess. On a busy cluster it is too short and
# the next cell measures the OLD surface, which reads on stage as the gateway ignoring
# the change. This asks the gateway what it is serving and waits for the answer to be
# the one expected, then returns immediately.
#
# The mode is identified by which meta tools are present, not by counting, so it is
# unaffected by an authorization policy filtering the list:
#
#   Standard    neither get_tool nor run_code
#   Search      get_tool and invoke_tool
#   Code        run_code, no get_tool
#   CodeSearch  get_tool and run_code
set -uo pipefail
WANT="${1:?usage: wait-for-mode.sh <Standard|Search|Code|CodeSearch>}"
K="kubectl --context ${CTX:-kind-mesh1}"
NS="${NS:-kagent}"
TRIES="${TRIES:-45}"
FROM_POD="${FROM_POD:-deploy/prtriagejava}"

tools_via_pod() {
  $K -n "$NS" exec "$FROM_POD" -- sh -c '
    U=http://github-mcp.'"$NS"'.svc.cluster.local/
    I='"'"'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"wait","version":"1"}}}'"'"'
    S=$(wget -qS -O /dev/null --header="Content-Type: application/json" --header="Accept: application/json, text/event-stream" --post-data="$I" $U 2>&1 | grep -i mcp-session-id | awk "{print \$2}")
    wget -qO- --header="Content-Type: application/json" --header="Accept: application/json, text/event-stream" ${S:+--header="Mcp-Session-Id: $S"} \
      --post-data='"'"'{"jsonrpc":"2.0","id":2,"method":"tools/list"}'"'"' $U 2>&1 \
      | grep -o "\"name\":\"[a-z_]*\"" | sed "s/\"name\"://;s/\"//g" | tr "\n" " "' 2>/dev/null
}

matches() { # matches "<tool list>"
  local t=" $1 "
  local has_get=1 has_run=1 has_inv=1
  [[ "$t" == *" get_tool "* ]]     || has_get=0
  [[ "$t" == *" run_code "* ]]     || has_run=0
  [[ "$t" == *" invoke_tool "* ]]  || has_inv=0
  [[ -z "${1// }" ]] && return 1   # nothing yet, or fully denied
  case "$WANT" in
    Standard)   [ "$has_get" = 0 ] && [ "$has_run" = 0 ] ;;
    Search)     [ "$has_get" = 1 ] && [ "$has_inv" = 1 ] ;;
    Code)       [ "$has_run" = 1 ] && [ "$has_get" = 0 ] ;;
    CodeSearch) [ "$has_get" = 1 ] && [ "$has_run" = 1 ] ;;
    *) echo "  ✗ unknown mode '$WANT'" >&2; return 2 ;;
  esac
}

for i in $(seq 1 "$TRIES"); do
  seen="$(tools_via_pod)"
  if matches "$seen"; then
    n=$(echo $seen | wc -w | tr -d ' ')
    echo "  ✓ gateway is serving $WANT ($n tools) after $((i*2))s"
    exit 0
  fi
  sleep 2
done
echo "  ✗ gateway never served $WANT within $((TRIES*2))s"
echo "    last seen: ${seen:-<nothing>}"
echo "    check:     kubectl -n $NS get enterpriseagentgatewaybackend github-mcp -o jsonpath='{.spec.entMcp.toolMode}'"
exit 1
