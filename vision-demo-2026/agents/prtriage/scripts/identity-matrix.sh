#!/usr/bin/env bash
# identity-matrix.sh — one GitHub integration, three callers, three sets of tools.
#
# Each caller runs the SAME one-line program in the gateway's sandbox, asking which
# GitHub functions exist in there. Nothing about the request differs except who makes
# it: same URL, same body, no credentials anywhere. The gateway generates the functions
# per caller from its authorization policy, so the answer is the policy, read back.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Object.keys(globalThis) is how a program sees its own tool surface. The sandbox has no
# console and no way out, so this is the only way to ask it.
cat > /tmp/probe-params.json <<'JSON'
{"name": "run_code",
 "arguments": {"code": "Object.keys(globalThis).filter(k => typeof globalThis[k] === 'function').sort()"}}
JSON

functions_for() { # functions_for <deployment>
  "$HERE/mcp-from-pod.sh" "$1" tools/call /tmp/probe-params.json \
    | grep -o '"success":\[[^]]*\]' | grep -o '"[a-z_]*"' | tr -d '"' | grep -v '^success$' \
    | sort | tr '\n' ' '
}

row() { # row <label> <functions...>
  local label="$1"; shift; local fns="$*"
  local read="no" merge="not defined"
  [[ "$fns" == *list_pull_requests* ]] && read="yes"
  [[ "$fns" == *merge_pull_request* ]] && merge="DEFINED"
  [[ -z "${fns// }" ]] && { read="DENIED"; merge="DENIED"; }
  printf "  %-18s %-10s %-12s %s\n" "$label" "$read" "$merge" "${fns:-(refused)}"
}

echo
printf "  %-18s %-10s %-12s %s\n" "identity" "read PRs" "merge"  "functions in its sandbox"
printf "  %-18s %-10s %-12s %s\n" "------------------" "--------" "-----------" "------------------------"
row "triage agent"  "$(functions_for prtriagejava)"
row "release agent" "$(functions_for releasejava)"

# my-mcp is an ordinary pod in the namespace. It IS in the mesh, so it has an identity,
# just not one the policy names. That is the honest third row and the common case: some
# other workload that found the endpoint.
K="kubectl --context ${CTX:-kind-mesh1}"
if $K -n "${NS:-kagent}" get deploy/my-mcp >/dev/null 2>&1; then
  row "another workload" "$(functions_for my-mcp)"
else
  echo "  (deploy/my-mcp is not present, so the unnamed-identity row is skipped)"
fi
echo
