#!/usr/bin/env bash
# Keycloak for the sovereign AI demo: deploy it, and mint tokens from it.
#
#   ./scripts/keycloak.sh up              deploy and wait for ready
#   ./scripts/keycloak.sh token alice     print alice's access token
#   ./scripts/keycloak.sh claims alice    print the decoded claims
#   ./scripts/keycloak.sh issuer          print the issuer the tokens actually carry
#   ./scripts/keycloak.sh check           prove the token iss matches yaml/32-jwt-policy.yaml
#   ./scripts/keycloak.sh down            remove it
#
# The realm lives in yaml/37-keycloak-realm.json and reaches the pod as a ConfigMap,
# which is why this exists rather than a plain kubectl apply.
#
# `check` is the one that matters. A mismatch between the token's iss claim and the
# policy's issuer string produces a 401 that is indistinguishable from a missing
# token, and it is the single most common way this lane fails. Run it before every
# rehearsal rather than reading the two strings and assuming they agree.
set -euo pipefail

# Required, not defaulted. This shell exports AWS_PROFILE=weaveone, so a ${VAR:-default}
# would silently inherit the wrong account, and the profile name itself contains the
# account id so it cannot be hardcoded in a file that is served publicly. :? fails loudly
# instead, which is the right trade for something that picks an AWS account.
export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai

# Always address the cluster explicitly. This laptop has a dozen kube contexts and any
# kind cluster that gets created steals current-context.
# Derived, never hardcoded: this file is served publicly from the site, so the account
# id does not belong in it. sts get-caller-identity also guarantees it matches whichever
# profile is actually in effect, which a hardcoded value cannot.
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=keycloak
REALM=sovereign
CLIENT=sovereign-ai
LOCAL_PORT=18080

# Must match KC_HOSTNAME in yaml/37-keycloak.yaml, with no port, because the Service
# listens on 80.
ISSUER="http://keycloak.${NS}.svc.cluster.local/realms/${REALM}"

die() { echo "error: $*" >&2; exit 1; }

# Port-forward for the length of one command. Keycloak is not exposed publicly and is
# not going to be: the IdP sits in the UK and is unreachable from outside the cluster.
with_pf() {
  local pf
  kc -n "$NS" port-forward svc/keycloak "${LOCAL_PORT}:80" >/dev/null 2>&1 & pf=$!
  trap 'kill '"$pf"' 2>/dev/null || true' RETURN
  local ok=""
  for _ in $(seq 1 30); do
    if curl -sf -o /dev/null "http://localhost:${LOCAL_PORT}/realms/${REALM}/.well-known/openid-configuration"; then
      ok=1; break
    fi
    sleep 1
  done
  [[ -n "$ok" ]] || die "Keycloak did not answer on localhost:${LOCAL_PORT} (is it up? try: $0 up)"
  "$@"
}

mint() {
  local user="${1:?usage: $0 token <alice|bob|carol>}"
  curl -s -X POST "http://localhost:${LOCAL_PORT}/realms/${REALM}/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=password&client_id=${CLIENT}&username=${user}&password=${user}" \
  | python3 -c 'import json,sys; t=json.load(sys.stdin).get("access_token",""); print(t)'
}

decode() {
  # JWT payload is base64url with the padding stripped, so put it back before decoding.
  python3 -c '
import base64, json, sys
tok = sys.stdin.read().strip()
if not tok or tok.count(".") < 2:
    sys.exit("no token to decode")
p = tok.split(".")[1]
p += "=" * (-len(p) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2, sort_keys=True))'
}

case "${1:-}" in
  up)
    # Namespace and realm ConfigMap first, THEN the StatefulSet. Doing it the other
    # way round works, but the pod spends its first half-minute in ContainerCreating
    # with "MountVolume.SetUp failed ... configmap keycloak-realm-import not found",
    # which is a confusing thing to hit on a first install and looks like a real fault.
    kc apply -f "$DIR/yaml/37-keycloak.yaml" --dry-run=client -o yaml >/dev/null
    python3 - "$DIR/yaml/37-keycloak.yaml" <<'PY' | kc apply -f -
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Namespace"]
print(yaml.safe_dump_all(docs))
PY
    # Recreated every time so an edit to the realm json actually takes effect. The
    # realm is only imported at startup, hence the rollout restart below.
    kc -n "$NS" create configmap keycloak-realm-import \
      --from-file=realm-sovereign.json="$DIR/yaml/37-keycloak-realm.json" \
      --dry-run=client -o yaml | kc apply -f -
    kc apply -f "$DIR/yaml/37-keycloak.yaml"
    # Only needed when re-running against an existing pod to pick up a realm edit. On
    # a fresh install there is nothing to restart and this is a harmless no-op.
    kc -n "$NS" rollout restart statefulset/keycloak 2>/dev/null || true
    echo "waiting for Keycloak to be ready (first start imports the realm, ~40s)..."
    kc -n "$NS" rollout status statefulset/keycloak --timeout=300s
    echo
    echo "issuer: ${ISSUER}"
    echo "users:  alice/alice (platform)  bob/bob (research)  carol/carol (admin)"
    echo "next:   $0 check"
    ;;

  token)
    with_pf mint "${2:-}"
    ;;

  claims)
    with_pf mint "${2:-alice}" | decode
    ;;

  issuer)
    with_pf mint alice | decode | python3 -c 'import json,sys; print(json.load(sys.stdin)["iss"])'
    ;;

  check)
    tok_iss="$(with_pf mint alice | decode | python3 -c 'import json,sys; print(json.load(sys.stdin)["iss"])')"
    pol="$DIR/yaml/32-jwt-policy.yaml"
    pol_iss="$(python3 - "$pol" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d["spec"]["traffic"]["jwtAuthentication"]["providers"][0]["issuer"])
PY
)"
    echo "token iss:     ${tok_iss}"
    echo "policy issuer: ${pol_iss}"
    if [[ "$tok_iss" == "$pol_iss" ]]; then
      echo "MATCH. The gateway will accept this token."
    else
      echo "MISMATCH. Every request will 401 and it will look like a missing token."
      echo "Fix KC_HOSTNAME in yaml/37-keycloak.yaml or the issuer in yaml/32-jwt-policy.yaml."
      exit 1
    fi
    # The audience has to be right too, and it fails just as silently.
    aud="$(with_pf mint alice | decode | python3 -c 'import json,sys; a=json.load(sys.stdin).get("aud"); print(a if isinstance(a,str) else ",".join(a or []))')"
    echo "token aud:     ${aud}"
    case ",${aud}," in
      *",${CLIENT},"*) echo "Audience contains ${CLIENT}. Good." ;;
      *) echo "WARNING: ${CLIENT} is not in aud. The policy's audiences list will reject this."; exit 1 ;;
    esac
    ;;

  down)
    kc delete -f "$DIR/yaml/37-keycloak.yaml" --ignore-not-found
    ;;

  *)
    echo "usage: $0 {up|token <user>|claims <user>|issuer|check|down}"; exit 1 ;;
esac
