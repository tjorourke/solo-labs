#!/usr/bin/env bash
# 40-gateway-config.sh — render yaml/portfolio-routes.yaml.tmpl with the
# captured runtime ARNs + invoke roles and apply it: 2 namespaces, 4 backends
# (agentCore ARN + assumeRole), 4 HTTPRoutes, 2 JWT policies.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
load_tofu_env
for v in PORTFOLIO_A_POET_ARN PORTFOLIO_A_QUANT_ARN PORTFOLIO_B_POET_ARN PORTFOLIO_B_QUANT_ARN; do
  [[ -n "${!v:-}" ]] || die "$v not set — run ./scripts/32-wait-runtimes.sh first"
done

step "Rendering + applying the portfolio gateway config"
export GW_NAME GW_NS AGENTS_HOST KEYCLOAK_ISSUER KEYCLOAK_NS KEYCLOAK_REALM \
  PORTFOLIO_A_POET_ARN PORTFOLIO_A_QUANT_ARN PORTFOLIO_B_POET_ARN PORTFOLIO_B_QUANT_ARN \
  PORTFOLIO_A_INVOKE_ROLE_ARN PORTFOLIO_B_INVOKE_ROLE_ARN
envsubst < "$LAB_ROOT/yaml/portfolio-routes.yaml.tmpl" | kc apply -f - >&2
ok "portfolio config applied"

step "Waiting for the routes to attach"
for ns in portfolio-a portfolio-b; do
  for r in poet quant; do
    for _ in $(seq 1 30); do
      ACC="$(kc -n "$ns" get httproute "$r" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
      [[ "$ACC" == "True" ]] && break; sleep 2
    done
    [[ "$ACC" == "True" ]] && ok "$ns/$r Accepted" || warn "$ns/$r not Accepted — check: kc -n $ns describe httproute $r"
  done
done
echo "  Next: ./scripts/41-invoke.sh" >&2
