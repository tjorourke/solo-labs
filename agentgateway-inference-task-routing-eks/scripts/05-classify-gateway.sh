#!/usr/bin/env bash
# Step 4 of the flow: the classify gateway authenticates, classifies, and hands on, behind an
# intake listener that normalises whatever a client sent.
#
#   ./scripts/05-classify-gateway.sh
#
# Replaces Part 3's policy and route on model-gateway with this part's: verify the token and
# keep it, run the router, send everything to the decision gateway. Then adds the intake
# listener in front of it on the same Gateway, which rewrites the model name to the one the
# router answers to and drops tool shapes the backends cannot take, so an editor or an agent
# works without being told what to send. scripts/99-restore.sh puts Part 3's back.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
[ -f "$HERE/identity/jwks.json" ] || { echo "error: no identity/jwks.json. Run ./scripts/01-identity.sh" >&2; exit 1; }
banner "Part 3's policy and route on model-gateway, if present"
kubectl -n "$NS" delete enterpriseagentgatewaypolicy identity-then-semantic --ignore-not-found
kubectl -n "$NS" delete httproute identity-routing --ignore-not-found
banner "policy, with the lab JWKS inlined"
JWKS="$(tr -d '\n' < "$HERE/identity/jwks.json")"
JWKS="$JWKS" python3 - "$HERE/yaml/70-classify-policy.yaml.tmpl" "$HERE/yaml/70-classify-policy.yaml" <<'PY'
import os, sys
open(sys.argv[2], "w").write(open(sys.argv[1]).read().replace("__JWKS__", os.environ["JWKS"]))
PY
kubectl apply -f "$HERE/yaml/70-classify-policy.yaml"
banner "route"
kubectl apply -f "$HERE/yaml/80-classify-route.yaml"

banner "the intake listener on the same Gateway"
# No second Gateway: yaml/platform/05-gateway.yaml gives model-gateway an :8080 listener and
# these two attach to it by sectionName, so the rewrite lands before the router reads the body.
kubectl apply -f "$HERE/yaml/platform/05-gateway.yaml"
kubectl -n "$NS" wait --for=condition=Programmed gateway/model-gateway --timeout=180s
kubectl apply -f "$HERE/yaml/91-intake-policy.yaml"
kubectl apply -f "$HERE/yaml/92-intake-route.yaml"
sleep 3
banner "attachment status"
kubectl -n "$NS" get enterpriseagentgatewaypolicy classify -o jsonpath='{range .status.ancestors[*]}{range .conditions[*]}{.type}={.status}  {.message}{"\n"}{end}{end}'
kubectl -n "$NS" get httproute classify-then-decide -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status}{"\n"}{end}' | sort -u
kubectl -n "$NS" get enterpriseagentgatewaypolicy normalise-model -o jsonpath='{range .status.ancestors[*]}{range .conditions[*]}{.type}={.status}  {.message}{"\n"}{end}{end}'
echo
echo "Next: source identity/tokens.env; ./scripts/06-test-flow.sh"
