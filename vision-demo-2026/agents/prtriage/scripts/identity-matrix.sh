#!/usr/bin/env bash
# identity-matrix.sh — one GitHub integration, three callers, three sets of tools.
#
# Each caller runs the SAME one-line program in the gateway's sandbox, asking which
# GitHub functions exist in there. Nothing about the request differs except who makes
# it: same URL, same body, no credentials anywhere. The gateway generates the functions
# per caller from its authorization policy, so the answer is the policy, read back.
#
# THE RULE THIS SCRIPT LEARNED THE HARD WAY
# An empty answer must never be printed as a denial unless the gateway actually denied
# it. A pod with no HTTP client, a deployment that is not there, and a gateway in a mode
# with no run_code all produce nothing, and all three once showed up in this table as
# DENIED. Every one of those is now a named error instead of a row.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="kubectl --context ${CTX:-kind-mesh1}"
NS="${NS:-kagent}"

# The probe IS a program, so the gateway has to be offering run_code. In Standard mode
# it is not, and every row would read DENIED for the wrong reason.
MODE="$($K -n "$NS" get enterpriseagentgatewaybackend github-mcp \
        -o jsonpath='{.spec.entMcp.toolMode}' 2>/dev/null)"
case "$MODE" in
  Code|CodeSearch) ;;
  *)
    echo
    echo "  This reads the policy out of the gateway's code sandbox, so it needs a mode"
    echo "  that offers run_code. The backend is currently toolMode=${MODE:-unknown}."
    echo "  Run section 6 first, or set it directly:"
    echo
    echo "    for ns in agentgateway-system kagent; do"
    echo "      kubectl -n \$ns patch enterpriseagentgatewaybackend github-mcp --type merge \\"
    echo "        -p '{\"spec\": {\"entMcp\": {\"toolMode\": \"CodeSearch\"}}}'"
    echo "    done"
    echo
    exit 1 ;;
esac

cat > /tmp/probe-params.json <<'JSON'
{"name": "run_code",
 "arguments": {"code": "Object.keys(globalThis).filter(k => typeof globalThis[k] === 'function').sort()"}}
JSON

functions_for() { # functions_for <deployment> — prints the functions, returns the probe's status
  local out st
  out="$("$HERE/mcp-from-pod.sh" "$1" tools/call /tmp/probe-params.json 2>/tmp/probe-err)"; st=$?
  [ "$st" -ne 0 ] && return "$st"
  printf '%s' "$out" | grep -o '"success":\[[^]]*\]' | grep -o '"[a-z_]*"' | tr -d '"' \
    | grep -v '^success$' | sort | tr '\n' ' '
  return 0
}

row() { # row <label> <deployment>
  local label="$1" dep="$2" fns st read merge n
  # The status has to come off the command substitution itself. Setting a global inside
  # functions_for does not work: it runs in a subshell, so the parent never sees it, and
  # a workload that could not be probed was printing as though policy had denied it.
  fns="$(functions_for "$dep")"; st=$?
  if [ "$st" -ne 0 ]; then
    printf "  %-18s %s\n" "$label" "not probed: $(sed -n '1s/^mcp-from-pod: //p' /tmp/probe-err)"
    return
  fi
  read="no"; merge="no"
  [[ "$fns" == *list_pull_requests* ]] && read="yes"
  [[ "$fns" == *merge_pull_request* ]] && merge="yes"
  if [ -z "${fns// }" ]; then
    read="none"; merge="none"; fns="the gateway generated nothing for it"
  else
    # 93 names is a wall nobody can read on a projector. Past a handful, count them and
    # name the ones that matter.
    n=$(printf '%s' "$fns" | wc -w | tr -d ' ')
    [ "$n" -gt 6 ] && fns="$n functions, including $(printf '%s' "$fns" | tr ' ' '\n' \
        | grep -E '^(merge_pull_request|delete_file|push_files|create_repository)$' | tr '\n' ' ')"
  fi
  printf "  %-18s %-10s %-10s %s\n" "$label" "$read" "$merge" "$fns"
}

echo
printf "  %-18s %-10s %-10s %s\n" "agent" "can read" "can merge" "what the gateway generated for it"
printf "  %-18s %-10s %-10s %s\n" "------------------" "--------" "---------" "---------------------------------"
row "triage agent"     prtriagejava
row "release agent"    releasejava
# The third row is the common case: another team's agent, in the same namespace, wired
# to the same approved GitHub server in the catalogue, and not named in the policy.
row "changelog agent"  changelogjava
echo
