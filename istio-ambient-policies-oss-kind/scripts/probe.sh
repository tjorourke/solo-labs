#!/usr/bin/env bash
# probe.sh: the same five calls to ratings, every time. Run it after each
# policy and read the column that changed.
#
#   reviews-v2   GET   in mesh, sa bookinfo-reviews: the caller ratings expects
#   reviews-v2   POST  same identity, a method the L7 policy refuses
#   demo-client  GET   in mesh, sa bookinfo-demo-client: an identity the policies refuse
#   legacy       GET   NOT in mesh, plaintext
#   reviews-v2   POST  with a signed JWT (policy 4)
#
# "000" is curl's code for a connection that never completed: a reset or a
# refusal. That is what an L4 deny looks like from the caller, as opposed to
# an L7 deny, which is a real HTTP 403 response.
#
#   ./scripts/probe.sh            # the table
#   ./scripts/probe.sh --no-jwt   # skip the token row (before policy 4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

with_jwt=1
[[ "${1:-}" == "--no-jwt" ]] && with_jwt=0

explain() { # <code>
  case "$1" in
    200) printf 'allowed' ;;
    401) printf 'denied: bad or missing token (L7, waypoint)' ;;
    403) printf 'denied: HTTP 403 (L7, waypoint)' ;;
    503) printf 'denied upstream: waypoint -> ratings reset (L4, ztunnel)' ;;
    000) printf 'denied: connection reset (L4, ztunnel)' ;;
    *)   printf 'unexpected' ;;
  esac
}

row() { # <caller> <ns> <method> <note> [curl args...]
  local caller="$1" ns="$2" method="$3" note="$4"; shift 4
  local code; code="$(curl_code "$ns" "$caller" "$method" "$@")"
  printf '  %-12s %-6s %-22s %s  %s\n' "$caller" "$method" "$note" "$code" "$(explain "$code")"
}

body=(-H 'Content-Type: application/json' -d '{"reviewerId":"probe","productId":0,"rating":4}')
printf '\n  %-12s %-6s %-22s %s\n' CALLER METHOD NOTE RESULT
printf '  %s\n' "────────────────────────────────────────────────────────────────────────────"
row reviews-v2  "$NS_APP"    GET  "in mesh"
row reviews-v2  "$NS_APP"    POST "in mesh" "${body[@]}"
row demo-client "$NS_APP"    GET  "in mesh"
row legacy      "$NS_LEGACY" GET  "NOT in mesh (plaintext)"
if (( with_jwt )); then
  row reviews-v2 "$NS_APP" POST "in mesh, signed JWT" "${body[@]}" -H "Authorization: Bearer $(cat "$LAB_ROOT/jwt/demo.jwt")"
fi
echo
