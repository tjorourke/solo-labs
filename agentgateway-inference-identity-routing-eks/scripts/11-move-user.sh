#!/usr/bin/env bash
# Change one attribute of one user and watch the same prompt run somewhere else.
#
#   ./scripts/11-move-user.sh alice restricted    # alice's work is now restricted: it stays on the GPU
#   ./scripts/11-move-user.sh carol internal      # carol may now use her contracted frontier provider
#
# Nothing else changes: not the client, not the router, not the route, not the backends.
# The script rewrites the user's data classification in the entitlement ConfigMap,
# restarts OPA so it reloads its data, and sends the hard prompt as that user.
# opa/entitlements.json on disk is left alone; ./scripts/04-opa.sh puts the cluster back
# to what the file says.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens
USER_NAME="${1:?usage: $0 <alice|bob|carol> <internal|restricted>}"
DATA="${2:?usage: $0 <alice|bob|carol> <internal|restricted>}"
case "$DATA" in internal|restricted) ;; *) echo "error: classification must be internal or restricted" >&2; exit 1 ;; esac
TOK_VAR="$(echo "$USER_NAME" | tr a-z A-Z)_TOKEN"; TOK="${!TOK_VAR:-}"
[ -n "$TOK" ] || { echo "error: no token for $USER_NAME" >&2; exit 1; }
TMP="${TMPDIR:-/tmp}/idr-entitlements.$$.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["users"][sys.argv[2]]["data"]=sys.argv[3]; json.dump(d,open(sys.argv[4],"w"),indent=2)' \
  "$HERE/opa/entitlements.json" "$USER_NAME" "$DATA" "$TMP"
banner "$USER_NAME -> data: $DATA in the entitlement data"
kubectl -n "$NS" create configmap opa-entitlements --from-file=entitlements.json="$TMP" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f "$TMP"
kubectl -n "$NS" rollout restart deploy/opa >/dev/null
kubectl -n "$NS" rollout status deploy/opa --timeout=180s >/dev/null
banner "the same hard prompt, as $USER_NAME"
gw_up; sleep 1
gw_curl "$TOK" "$(chat "$HARD")"
echo "status:   $STATUS"
echo "target:   $(target)"
echo "class:    $(class)"
echo "model:    $(resp_model)"
echo
echo "Restore the file's entitlements with:  ./scripts/04-opa.sh"
