#!/usr/bin/env bash
# 04b-register-runtime.sh — register the kagent platform as a Kagent Runtime, so
# the AR UI renders it under Runtimes and deploys flow through the kagent
# controller (showing live instances). Platform plumbing (done by setup.sh); the
# notebook's deploy is then a clean one-liner against the existing runtime.
#
# Type Kagent (not Kubernetes): a Kagent runtime deploys via the controller's HTTP
# API and FORWARDS the caller's Keycloak bearer to it. That's why the daemon runs
# behind the same Keycloak (04-daemon) and the controller is exposed via a NodePort
# (kagentUrl = ${KAGENT_URL}). A Kubernetes-type runtime would deploy via kubeconfig
# but is NOT rendered as a kagent platform in the UI — the whole point here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
arctl_token

step "Registering the Kagent Runtime 'kind-kagent' (kagentUrl ${KAGENT_URL})"
arctl apply -f - <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: kind-kagent
spec:
  type: Kagent
  config:
    kagentUrl: "${KAGENT_URL}"
    namespace: kagent
EOF
ok "runtime kind-kagent registered (Kagent)"

step "Registry hygiene (clean-slate)"
# The daemon's data survives cluster rebuilds and the daemon re-seeds default
# runtimes (virtual-default, kubernetes-default) on start; it may also carry
# agents/deployments from a previous run (e.g. a stale 'summarizer'). Drop them so
# the registry shows only the connected platforms + the catalog 04c publishes; the
# notebook then creates the agent. Keep 'local' (used by `arctl run`) and kind-kagent;
# aws-agentcore is added next by 04d.
clean_names() { arctl get "$1" 2>/dev/null | awk 'NR>1{print $1}' | sed 's#^.*/##'; }
for r in virtual-default kubernetes-default; do arctl delete runtime "$r" >/dev/null 2>&1 || true; done
for d in $(clean_names deployments); do [ -n "$d" ] && arctl delete deployment "$d" >/dev/null 2>&1 || true; done
for a in $(clean_names agents);      do [ -n "$a" ] && arctl delete agent "$a"      >/dev/null 2>&1 || true; done

step "Verifying the kagent platform is registered and reachable"
arctl get runtime kind-kagent >/dev/null 2>&1 || die "kind-kagent runtime not registered"
# The daemon reaches the controller via the NodePort (the runtime's kagentUrl).
docker exec "$DAEMON_CONTAINER" bash -c "timeout 5 bash -c 'echo > /dev/tcp/${CLUSTER_NAME}-control-plane/${CONTROLLER_NODEPORT}'" >/dev/null 2>&1 \
  && ok "daemon can reach the kagent controller at ${KAGENT_URL}" \
  || warn "daemon could not TCP-reach ${KAGENT_URL} — deploys may fail"
ok "kagent platform 'kind-kagent' registered"
arctl get runtimes 2>/dev/null | sed 's/^/  /' >&2 || true
