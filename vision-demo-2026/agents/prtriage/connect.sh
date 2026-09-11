#!/usr/bin/env bash
# connect.sh — prepare a shell for this part. SOURCE it. The same one line works in the
# notebook's Connect cell and in a terminal, from any directory:
#
#     source agents/prtriage/connect.sh
#
# It changes NOTHING in the cluster. No restarts, no policy, no toolMode, no seeding,
# no port killing, no rewriting of another part's files. So it is safe to run at any
# point, including halfway through the demo, and running it twice does nothing twice.
#
# After this: kubectl talks to mesh1 with no --context, arctl is logged in, and the
# demo's own commands (mcp, ask, try-merge, ...) are on PATH.

# Resolve this file's own location rather than the caller's, so where you happen to be
# standing does not matter.
_p8_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_p8_suite="$(cd "$_p8_here/../.." && pwd)"
cd "$_p8_suite" || return 1

# ANTHROPIC_API_KEY and the GitHub PAT. Quiet when the file is not there: the cluster
# holds its own copies, and the only cell that needs the key locally is the token count.
set -a; . "${SECRETS_FILE:-$HOME/code/solo/secrets/secrets-envs.sh}" 2>/dev/null; set +a

# Platform facts (LB address, the sslip hostnames, the Keycloak clients) and the helper
# functions. This is lib.sh and deliberately not demo-4's connect.sh, which also frees
# local ports and re-stamps a scaffolded agent's .env file.
. demo-scripts/agentregistry/scripts/lib.sh
unset ARCTL_API_TOKEN          # a stale one wins over the login token and 401s everything
arctl_login >/dev/null 2>&1 \
  && echo "  arctl      logged in to ${ARCTL_API_BASE_URL} as ${AS_USER}" \
  || echo "  arctl      NOT logged in — is the platform up? run agents/prtriage/scripts/setup.sh"

# A kubeconfig holding only this cluster, so every cell and every pasted command can say
# plain `kubectl`. Writing our own file rather than switching the laptop's current
# context means no other terminal changes under you.
kubectl config view --raw --minify --context kind-mesh1 > /tmp/demo8.kubeconfig 2>/dev/null \
  && export KUBECONFIG=/tmp/demo8.kubeconfig \
  && kubectl config use-context kind-mesh1 >/dev/null 2>&1 \
  && echo "  kubectl    kind-mesh1 (via \$KUBECONFIG=/tmp/demo8.kubeconfig)" \
  || echo "  kubectl    no kind-mesh1 context found"

# mcp, ask, try-merge, wait-for-mode, reload-agent, identity-matrix, check-report,
# trace-cost, sandbox-probe, compare-modes.
case ":$PATH:" in
  *":$_p8_suite/agents/prtriage/bin:"*) ;;
  *) export PATH="$_p8_suite/agents/prtriage/bin:$PATH" ;;
esac
export DEMO_REPO="${DEMO_REPO:-tjorourke/kagent}"

echo "  commands   $(cd agents/prtriage/bin && echo *)"
echo
echo "  kagent UI       http://${KAGENT_UI_HOST}"
echo "  AgentRegistry   http://${AR_HOST}"
echo "  pull requests   https://github.com/${DEMO_REPO}/pulls"
unset _p8_here _p8_suite
