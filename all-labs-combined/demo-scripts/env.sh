# env.sh — terminal twin of each notebook's Connect cell.
#
#   source demo-scripts/env.sh <1|2|3|4|5|6>
#
# Sets the same variables (CTX, ISTIOCTL, licences, …) that the matching
# demo-N notebook's first cell exports, and cd's to the right directory, so you
# can paste the notebook's kubectl / istioctl / helm / arctl / curl commands
# straight into the terminal instead of opening the .ipynb.
#
# MUST be sourced (not executed) so the exports land in your shell:
#   source demo-scripts/env.sh 3      ✓
#   ./demo-scripts/env.sh 3           ✗ (exports vanish)

# resolve the lab root (the dir holding the demo-N notebooks) regardless of CWD
_ENV_SRC="${BASH_SOURCE[0]:-$0}"
LAB_ROOT="$(cd "$(dirname "$_ENV_SRC")/.." && pwd)"

DEMO="${1:-}"
case "$DEMO" in
  1|2|3|4|5|6|7) : ;;
  *)
    echo "usage: source demo-scripts/env.sh <1|2|3|4|5|6|7>"
    echo "  1  istio ambient multicluster (mesh1+mesh2)"
    echo "  2  ztunnel L4 identity        (mesh1)"
    echo "  3  waypoint L7                (mesh1)"
    echo "  4  agentregistry + arctl login (mesh1)"
    echo "  5  kagent substrate / gVisor  (substrate)"
    echo "  6  inference routing / GIE    (inference)"
    echo "  7  AI gateway                 (mesh1)"
    return 2 2>/dev/null || exit 2
    ;;
esac

# licences / API keys — every demo wants these
export SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
[ -f "$SECRETS_FILE" ] && set -a && . "$SECRETS_FILE" && set +a
_lic() { [ -n "$SOLO_ISTIO_LICENSE_KEY" ] && echo yes || echo NO; }

case "$DEMO" in
  1)
    cd "$LAB_ROOT" || return 1
    export CLUSTER1=kind-mesh1 CLUSTER2=kind-mesh2 CTX=kind-mesh1
    export ISTIOCTL=$HOME/.istioctl/bin/istioctl-1.30.3-solo
    echo "demo-1 · mesh1=$CLUSTER1  mesh2=$CLUSTER2 · licence: $(_lic)"
    $ISTIOCTL --context $CLUSTER1 multicluster check 2>&1 | grep -E "Peers Check|Gateway Check" \
      || echo "not peered: run ./demo-scripts/setup.sh (or ./demo-scripts/wake.sh after a sleep)"
    ;;
  2|3)
    cd "$LAB_ROOT" || return 1
    export CTX=kind-mesh1 ISTIO_NS=istio-system TD=mesh1
    export ISTIOCTL=$HOME/.istioctl/bin/istioctl-1.30.3-solo
    export HUB=us-docker.pkg.dev/soloio-img/istio TAG=1.30.3-solo
    export HREPO=oci://us-docker.pkg.dev/soloio-img/istio-helm HVER=1.30.3-solo
    echo "demo-$DEMO · context: $CTX · trust domain: $TD · licence: $(_lic)"
    kubectl --context $CTX -n $ISTIO_NS get ds ztunnel >/dev/null 2>&1 \
      && echo "ambient mesh: up on ${CTX#kind-}" \
      || echo "mesh not found on ${CTX#kind-}: run ./demo-scripts/setup.sh (or ./demo-scripts/wake.sh after a sleep)"
    ;;
  4)
    cd "$LAB_ROOT/demo-scripts/agentregistry" || return 1
    # sources arctl onto PATH + logs the CLI in to the in-cluster registry as admin-user
    source scripts/connect.sh
    echo "demo-4 · AgentRegistry UI: http://${AR_HOST}  ·  Keycloak: http://${KEYCLOAK_HOST} (admin-user / password)"
    echo "  cwd is demo-scripts/agentregistry — 'arctl apply -f yaml/...' paths are relative to here"
    ;;
  5)
    cd "$LAB_ROOT" || return 1
    export CTX=kind-substrate KAGENT_NS=kagent
    export KENT_CRDS_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds"
    export KENT_CHART="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise"
    export KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.5.2}"
    echo "demo-5 · context: $CTX · kagent-enterprise: $KAGENT_ENT_VERSION"
    kubectl --context $CTX get ns "$KAGENT_NS" >/dev/null 2>&1 \
      && echo "substrate cluster: up" \
      || echo "substrate not found: run ./demo-scripts/substrate-cluster.sh"
    ;;
  7)
    cd "$LAB_ROOT" || return 1
    export CTX=kind-mesh1 NS=agentgateway-system
    export GATEWAY=$(kubectl --context $CTX -n $NS get gateway ai-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
    echo "demo-7 · context: $CTX · GATEWAY=${GATEWAY:-<not up>} · licence: $(_lic)"
    [ -n "$GATEWAY" ] \
      || echo "ai-gateway not found: run SECRETS_FILE=\$SECRETS_FILE ./demo-scripts/ai-gateway.sh"
    ;;
  6)
    # demo-6 is a symlink to the standalone inference lab; its cells run from there
    INF_DIR="$(cd "$LAB_ROOT/.." && pwd)/agentgateway-inference-routing-kind"
    cd "$INF_DIR" || { echo "inference lab not found at $INF_DIR"; return 1; }
    export CTX=kind-inference NS=inference
    echo "demo-6 · context: $CTX · dir: $INF_DIR"
    kubectl --context $CTX get ns "$NS" >/dev/null 2>&1 \
      && echo "inference cluster: up" \
      || echo "inference not found: run ./scripts/quick.sh up"
    ;;
esac
