#!/usr/bin/env bash
# The frontier budget: show it, spend it, raise it.
#
#   ./scripts/09-budget.sh            what the budget is and whether it is enforced
#   ./scripts/09-budget.sh spend      send frontier questions until bob is refused
#   ./scripts/09-budget.sh set 20000  raise or lower the limit, in tokens
#
# The private models run on a card the bank already owns. The frontier is metered by
# someone else, so that is the route with a limit on it, and the limit belongs to a person:
# the subject is the `user` dimension from the verified token and the `modelPool` dimension
# from the header OPA writes. A caller cannot change either.
#
# Over the limit the gateway answers 429 and the request never reaches the provider. The
# private routes are untouched, which is the point: the budget removes the metered option,
# not the ability to work.
#
# Spend is counted per subject and window by the control plane, not by the resource, so
# deleting and recreating the budget does NOT clear it. The limit is the lever: before a
# demo set it high, and at the moment you want the refusal set it low, because the day's
# spend is already above it and the next frontier request is refused straight away.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/scripts/lib.sh"
load_tokens
BUDGET=frontier-budgets

case "${1:-show}" in
  show)
    banner "the budget"
    kubectl -n "$NS" get enterpriseagentgatewaybudget "$BUDGET" \
      -o jsonpath='{range .spec.budgets[*]}  {.name}: {.limit.amount} {.limit.unit} per {.window.unit}, subject {.subject}, over it {.onBudgetExceeded}{"\n"}{end}'
    banner "is it enforced?"
    kubectl -n "$NS" get enterpriseagentgatewaybudget "$BUDGET" \
      -o jsonpath='{range .status.conditions[*]}  {.type}={.status}  {.message}{"\n"}{end}'
    echo
    echo "A budget nothing selects is inert. yaml/46-budget-enforcement.yaml is the policy that"
    echo "switches enforcement on for the decision gateway, at PostRouting: the PreRouting phase"
    echo "does not carry budget enforcement, so it is its own policy rather than part of decide."
    ;;
  spend)
    gw_up
    banner "bob asks the one question that leaves the building, until he cannot"
    for i in $(seq 1 12); do
      gw_curl "$BOB_TOKEN" "$(chat "Show me a Java dependency injection example with a short explanation." )"
      printf '  %-2s %s  pool=%-18s %s\n' "$i" "$STATUS" "$(pool)" "$(resp_model)"
      [ "$STATUS" = "200" ] || break
    done
    banner "the private routes are untouched"
    # No braces-with-a-comma in a prompt written inline: bash expands {a,b} before the
    # quotes matter, the helper is handed two bodies, and curl fails in a way that reads
    # like the gateway refused it.
    gw_curl "$BOB_TOKEN" "$(chat "Review this ledger posting method for concurrency bugs.")"
    printf '  review  %s  pool=%-18s %s\n' "$STATUS" "$(pool)" "$(resp_model)"
    ;;
  set)
    n="${2:?usage: 09-budget.sh set <tokens>}"
    kubectl -n "$NS" patch enterpriseagentgatewaybudget "$BUDGET" --type merge \
      -p "{\"spec\":{\"budgets\":[{\"name\":\"bob-frontier-daily\",\"subject\":{\"user\":\"bob\",\"modelPool\":\"approved-frontier\"},\"limit\":{\"amount\":$n,\"unit\":\"Tokens\"},\"window\":{\"unit\":\"Day\"},\"onBudgetExceeded\":\"Block\"}]}}"
    echo "  bob's daily frontier budget is now $n tokens"
    ;;
  *) echo "usage: $0 {show|spend|set <tokens>}" >&2; exit 1 ;;
esac
