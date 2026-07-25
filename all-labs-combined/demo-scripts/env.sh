# Connect: contexts, the Solo istioctl build, licences. Safe to re-run (env only).
[ -d istio-ambient-demo-kind ] && cd istio-ambient-demo-kind || :
export CLUSTER1=kind-mesh1 CLUSTER2=kind-mesh2
export ISTIOCTL=$HOME/.istioctl/bin/istioctl-1.30.3-solo
export SECRETS_FILE="${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}"
[ -f "$SECRETS_FILE" ] && set -a && . "$SECRETS_FILE" && set +a
echo "mesh1=$CLUSTER1  mesh2=$CLUSTER2  licence: $([ -n "$SOLO_ISTIO_LICENSE_KEY" ] && echo yes || echo NO)"
$ISTIOCTL --context $CLUSTER1 multicluster check 2>&1 | grep -E "Peers Check|Gateway Check" || echo "not peered: run ./setup.sh (or ./demo-scripts/wake.sh after a sleep)"
