#!/usr/bin/env bash
# The combined PreRouting policy and the route.
#
#   ./scripts/07-routing.sh
#
# Renders yaml/70-policy.yaml from the template with identity/jwks.json inlined, removes
# Part 1's routing objects if they are present (they match the same host and path, and
# policies on one Gateway merge field by field), applies this part's policy and route,
# and prints the attachment status. scripts/99-restore.sh puts Part 1's back.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
[ -f "$HERE/identity/jwks.json" ] || { echo "error: no identity/jwks.json. Run ./scripts/03-identity.sh" >&2; exit 1; }
banner "Part 1's routing objects, if present"
kubectl -n "$NS" delete agentgatewaypolicy extract-model-internal --ignore-not-found
kubectl -n "$NS" delete httproute model-routing-internal --ignore-not-found
banner "policy, with the lab JWKS inlined"
JWKS="$(tr -d '\n' < "$HERE/identity/jwks.json")"
JWKS="$JWKS" python3 - "$HERE/yaml/70-policy.yaml.tmpl" "$HERE/yaml/70-policy.yaml" <<'PY'
import os, sys
t = open(sys.argv[1]).read().replace("__JWKS__", os.environ["JWKS"])
open(sys.argv[2], "w").write(t)
PY
kubectl apply -f "$HERE/yaml/70-policy.yaml"
banner "route"
kubectl apply -f "$HERE/yaml/80-httproute.yaml"
sleep 3
banner "attachment status"
kubectl -n "$NS" get agentgatewaypolicy identity-then-semantic \
  -o jsonpath='{range .status.ancestors[*]}{range .conditions[*]}{.type}={.status}  {.message}{"\n"}{end}{end}'
kubectl -n "$NS" get httproute identity-routing -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}' | sort -u
echo
echo "Next: source identity/tokens.env; ./scripts/09-test-matrix.sh"
