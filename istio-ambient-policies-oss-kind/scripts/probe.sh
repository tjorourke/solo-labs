#!/usr/bin/env bash
# probe.sh: the same five calls, every time. Run it after each policy and read
# the column that changed.
#
#   checkout   GET     in mesh, the identity the policies allow
#   checkout   DELETE  same identity, a method the L7 policy refuses
#   reporting  GET     in mesh, an identity the policies refuse
#   legacy     GET     NOT in mesh, plaintext
#   checkout   DELETE  with a signed JWT (step 7)
#
# "000" is curl's code for a connection that never completed: a reset or a
# refusal. That is what an L4 deny looks like from the caller, as opposed to
# an L7 deny, which is a real HTTP 403 response.
#
#   ./scripts/probe.sh            # the table
#   ./scripts/probe.sh --no-jwt   # skip the token row (before step 6)
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
    503) printf 'denied upstream: waypoint -> catalog reset (L4, ztunnel)' ;;
    000) printf 'denied: connection reset (L4, ztunnel)' ;;
    *)   printf 'unexpected' ;;
  esac
}

row() { # <caller> <ns> <method> <note> [curl args...]
  local caller="$1" ns="$2" method="$3" note="$4"; shift 4
  local code; code="$(curl_code "$ns" "$caller" "$method" "$@")"
  printf '  %-10s %-7s %-22s %s  %s\n' "$caller" "$method" "$note" "$code" "$(explain "$code")"
}

printf '\n  %-10s %-7s %-22s %s\n' CALLER METHOD NOTE RESULT
printf '  %s\n' "────────────────────────────────────────────────────────────────────────────"
row checkout  "$NS_SHOP"   GET    "in mesh"
row checkout  "$NS_SHOP"   DELETE "in mesh"
row reporting "$NS_SHOP"   GET    "in mesh"
row legacy    "$NS_LEGACY" GET    "NOT in mesh (plaintext)"
if (( with_jwt )); then
  row checkout "$NS_SHOP" DELETE "in mesh, signed JWT" -H "Authorization: Bearer $(cat "$LAB_ROOT/jwt/demo.jwt")"
fi
echo
