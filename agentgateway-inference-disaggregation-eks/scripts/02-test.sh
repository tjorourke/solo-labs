#!/usr/bin/env bash
# The headline: the same load, disaggregated and not, on the same two pods.
#
#   ./scripts/02-test.sh
#
# Two runs. The only difference between them is the decider's threshold, so the second
# run uses the second card and the first one does not. Everything else — the pods, the
# route, the picker, the gateway, the prompts — is identical.
#
# Read the VERDICT line and the per-pod token counts first. A 200 proves nothing here:
# FailOpen means a picker that never ran still serves every request, monolithically,
# while looking completely healthy.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
resolve_ctx

run() {
  # Reuse the load-balancing lab's loadgen pod: it is already on the platform nodes with
  # the right defaults, and building a second one would be a second thing to keep in step.
  kc -n "$NS" exec -i deploy/loadgen -- python3 - "$@" < "$LAB_ROOT/scripts/pd.py"
}

step "1/2  monolithic: prefill and decode together on the decode card"
"$LAB_ROOT/scripts/decider.sh" 999999
run --label "monolithic (nonCachedTokens=999999)"

step "2/2  disaggregated: prefill on card 1, decode on card 2, KV over NIXL"
"$LAB_ROOT/scripts/decider.sh" 16
run --label "disaggregated (nonCachedTokens=16)"

step "what the picker decided, per request"
# The EPP at v4 logs the profiles it ran. Two profile names on one request is a
# disaggregated one; one name is monolithic.
kc -n "$NS" logs deploy/pd-epp --tail=60 2>/dev/null \
  | grep -iE 'profile|prefill|decode' | tail -20 | sed 's/^/  /'

step "left disaggregated. Back to the load-balancing lab with: ./scripts/99-restore.sh"
