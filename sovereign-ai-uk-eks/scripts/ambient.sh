#!/usr/bin/env bash
# Solo Istio in ambient mode, as the identity layer under the whole stack.
#
#   ./scripts/ambient.sh up       base + istiod + cni + ztunnel
#   ./scripts/ambient.sh enrol    put models, agentgateway-system and keycloak in the mesh
#   ./scripts/ambient.sh status   what is running and which namespaces are enrolled
#   ./scripts/ambient.sh down     remove it
#
# Installed as the four Solo charts rather than through the Gloo Operator's
# ServiceMeshController. The operator hides licence, trust domain and log format behind
# a CR that does not expose them, so an operator install needs kubectl patches onto
# istiod and ztunnel afterwards. As Helm values they are declared once, here.
set -euo pipefail

export AWS_PROFILE="${SOVEREIGN_AWS_PROFILE:?set SOVEREIGN_AWS_PROFILE to the sandbox SSO profile}"
REGION=eu-west-2
CLUSTER=uk-sovereign-ai
NS=istio-system

# On the 1.30 line the image tag KEEPS the -solo suffix. The plain 1.30.x tag in the
# same registry is the upstream build with none of the Solo additions: it installs
# perfectly cleanly and then Solo-only features silently fail closed, which is a very
# expensive way to lose an afternoon. 1.29 was the other way round, chart -solo and
# image plain, so do not carry an assumption across minor versions.
SOLO_ISTIO_VERSION="${SOLO_ISTIO_VERSION:-1.30.3-solo}"
ISTIO_REGISTRY="${ISTIO_REGISTRY:-us-docker.pkg.dev/soloio-img/istio}"
HREPO="${ISTIO_HELM_REPO:-oci://us-docker.pkg.dev/soloio-img/istio-helm}"

# cluster.local, NOT a per-cluster trust domain. The enterprise-agentgateway waypoint
# binary hardcodes TRUST_DOMAIN=cluster.local, and this stack uses an agentgateway
# waypoint for L7 rather than the Istio one. A custom trust domain here produces a
# waypoint that cannot validate peers, and the symptom is a connection failure that
# looks like a policy problem.
TRUST_DOMAIN="${TRUST_DOMAIN:-cluster.local}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && [ "$ACCOUNT" != "None" ] || { echo "error: no AWS identity; check SOVEREIGN_AWS_PROFILE" >&2; exit 1; }
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"
kc() { command kubectl --context "$CTX" "$@"; }
helm_() { command helm --kube-context "$CTX" "$@"; }

license() {
  if [ -z "${SOLO_ISTIO_LICENSE_KEY:-}" ]; then
    # Optional convenience: point SOVEREIGN_ENV_FILE at your own env file that exports
    # the licence keys. Otherwise export them directly. No path is hardcoded, and no
    # secret ever lives in this repo.
    # shellcheck disable=SC1090
    [ -n "${SOVEREIGN_ENV_FILE:-}" ] && [ -f "$SOVEREIGN_ENV_FILE" ] && . "$SOVEREIGN_ENV_FILE" >/dev/null 2>&1 || true
  fi
  [ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ] || {
    echo "error: SOLO_ISTIO_LICENSE_KEY is not set. source your secrets env first." >&2; exit 1; }
}

case "${1:-status}" in
  up)
    license
    echo "==> istio-base (CRDs + cluster roles) $SOLO_ISTIO_VERSION"
    helm_ upgrade -i istio-base "$HREPO/base" -n "$NS" --create-namespace \
      --version "$SOLO_ISTIO_VERSION" --set defaultRevision=default --wait >/dev/null
    echo "    ok"

    echo "==> istiod (profile ambient), licence and trust domain as values"
    helm_ upgrade -i istiod "$HREPO/istiod" -n "$NS" \
      --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${SOLO_ISTIO_VERSION}
istio_cni:
  enabled: true
license:
  value: ${SOLO_ISTIO_LICENSE_KEY}
meshConfig:
  accessLogFile: /dev/stdout
  trustDomain: ${TRUST_DOMAIN}
EOF
    kc -n "$NS" rollout status deploy/istiod --timeout=300s
    echo "    ok, trust domain '${TRUST_DOMAIN}'"

    echo "==> istio-cni (node traffic capture)"
    # excludeNamespaces matters on EKS: capturing kube-system would put the CNI in the
    # path of aws-node itself, and a CNI that depends on the pod it is capturing is a
    # deadlock on every node restart.
    helm_ upgrade -i istio-cni "$HREPO/cni" -n "$NS" \
      --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
global:
  hub: ${ISTIO_REGISTRY}
  tag: ${SOLO_ISTIO_VERSION}
ambient:
  dnsCapture: true
excludeNamespaces:
  - istio-system
  - kube-system
EOF
    echo "    ok"

    echo "==> ztunnel (per-node L4 proxy), JSON access logs + L7 telemetry"
    helm_ upgrade -i ztunnel "$HREPO/ztunnel" -n "$NS" \
      --version "$SOLO_ISTIO_VERSION" --wait -f - >/dev/null <<EOF
profile: ambient
hub: ${ISTIO_REGISTRY}
tag: ${SOLO_ISTIO_VERSION}
namespace: ${NS}
istioNamespace: ${NS}
env:
  LOG_FORMAT: json
  L7_ENABLED: "true"
EOF
    kc -n "$NS" rollout status daemonset/ztunnel --timeout=300s
    kc -n "$NS" rollout status daemonset/istio-cni-node --timeout=300s
    echo "    ok, ztunnel and istio-cni on every node"
    ;;

  enrol)
    # Enrolment is a namespace label and nothing else. Doing it AFTER the workloads are
    # running is deliberate: the pods have to restart to be captured, so enrolling a
    # namespace mid-demo restarts the model, and vLLM takes minutes to come back.
    for ns in models agentgateway-system keycloak; do
      kc get ns "$ns" >/dev/null 2>&1 || { echo "    skip $ns (does not exist)"; continue; }
      kc label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null
      echo "    $ns -> ambient"
    done
    echo
    echo "note: existing pods are only captured after a restart. ztunnel picks up new"
    echo "      pods immediately, so restart deliberately rather than being surprised:"
    echo "      kubectl -n models rollout restart deploy/vllm   # costs a model reload"
    ;;

  status)
    echo "=== istio-system"
    kc -n "$NS" get pods 2>/dev/null || echo "  not installed"
    echo
    echo "=== trust domain actually in effect"
    kc -n "$NS" get cm istio -o jsonpath='{.data.mesh}' 2>/dev/null | grep -i trustdomain || echo "  (default)"
    echo
    echo "=== enrolled namespaces"
    kc get ns -L istio.io/dataplane-mode --no-headers 2>/dev/null | awk '$NF=="ambient"{print "  "$1}' || true
    ;;

  down)
    for r in ztunnel istio-cni istiod istio-base; do
      helm_ uninstall "$r" -n "$NS" >/dev/null 2>&1 && echo "  removed $r" || true
    done
    ;;

  *) echo "usage: $0 {up|enrol|status|down}"; exit 1 ;;
esac
